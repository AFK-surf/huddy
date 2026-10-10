//// Running reviews: one decision-model call per write, periodic sweeps, and
//// the deterministic checks. Results become findings in the store.

import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import huddy/ctx.{type Ctx}
import huddy/ephemeral
import huddy/jev
import huddy/model
import huddy/review
import huddy/state
import huddy/store
import huddy/sys
import logging

fn add_findings(
  s: model.State,
  findings: List(state.NewFinding),
  now: Int,
  cooldown_ms: Int,
) -> #(model.State, Int) {
  list.fold(findings, #(s, 0), fn(acc, f) {
    let #(s, n) = acc
    case state.add_finding(s, f, now, cooldown_ms) {
      #(s, Some(_)) -> #(s, n + 1)
      #(s, None) -> #(s, n)
    }
  })
}

fn cooldown(ctx: Ctx) -> Int {
  state.hours(ctx.config.review.dismiss_cooldown_hours)
}

/// Review one item now (blocking). No-op when the model is disabled or the
/// item is gone/closed.
pub fn review_item(ctx: Ctx, item_id: Int) -> Nil {
  case ctx.ask {
    None -> Nil
    Some(ask) -> {
      let prepared =
        store.read(ctx.store, fn(s, _) {
          case state.get_item(s, item_id) {
            Some(item) ->
              case model.is_open(item) {
                True -> Some(review.write_request(s, item, sys.now_ms()))
                False -> None
              }
            None -> None
          }
        })
      case prepared {
        None -> Nil
        Some(req) -> {
          let request_text =
            jev.request_json(
              ctx.config.decision_model.model,
              req.state,
              req.questions,
            )
            |> json.to_string
          let started = sys.now_ms()
          let result = ask(req.state, req.questions)
          let latency = sys.now_ms() - started
          let thresholds = ctx.config.review.thresholds
          let cd = cooldown(ctx)
          case result {
            Ok(resp) -> {
              let _ =
                store.update(ctx.store, fn(s, e, now) {
                  let #(s, judgment) =
                    state.add_judgment(
                      s,
                      now,
                      "write",
                      Some(item_id),
                      request_text,
                      Some(resp.raw),
                      latency,
                      resp.input_tokens,
                      resp.output_tokens,
                      None,
                    )
                  let still_current = case state.get_item(s, item_id) {
                    Some(i) ->
                      i.version == req.context.item.version && model.is_open(i)
                    None -> False
                  }
                  let s = case still_current {
                    True -> {
                      let #(importance, findings) =
                        review.interpret_write(
                          req.context,
                          resp.answers,
                          thresholds,
                          judgment,
                        )
                      let s =
                        state.set_review_result(
                          s,
                          item_id,
                          req.context.item.version,
                          importance,
                          now,
                        )
                      add_findings(s, findings, now, cd).0
                    }
                    False -> s
                  }
                  store.Changed(s, e, [store.Publish], Nil)
                })
              Nil
            }
            Error(reason) -> {
              logging.log(
                logging.Warning,
                "review of " <> model.item_ref(item_id) <> " failed: " <> reason,
              )
              store.update_lazy(ctx.store, fn(s, e, now) {
                let #(s, _) =
                  state.add_judgment(
                    s,
                    now,
                    "write",
                    Some(item_id),
                    request_text,
                    None,
                    latency,
                    0,
                    0,
                    Some(reason),
                  )
                store.Changed(s, e, [], Nil)
              })
            }
          }
        }
      }
    }
  }
}

/// Start a review and wait up to `wait_ms` for it. Returns True when the
/// review finished in time (or there was nothing to do).
pub fn review_with_deadline(ctx: Ctx, item_id: Int, wait_ms: Int) -> Bool {
  case ctx.ask {
    None -> True
    Some(_) -> {
      let done = process.new_subject()
      process.spawn_unlinked(fn() {
        review_item(ctx, item_id)
        process.send(done, Nil)
      })
      case process.receive(done, wait_ms) {
        Ok(_) -> True
        Error(_) -> False
      }
    }
  }
}

/// The deterministic part of a post: `too_many_open` (and resolve it when
/// back within the guideline).
pub fn check_open_counts(
  ctx: Ctx,
  s: model.State,
  agent_id: Int,
  now: Int,
) -> model.State {
  let r = ctx.config.review
  case
    review.too_many_open(
      s,
      agent_id,
      r.open_tasks_guideline,
      r.open_decisions_guideline,
    )
  {
    Some(f) -> state.add_finding(s, f, now, cooldown(ctx)).0
    None -> state.resolve_agent_findings(s, agent_id, model.TooManyOpen, now)
  }
}

/// The periodic sweep (§6.3).
pub fn sweep(ctx: Ctx) -> Nil {
  let r = ctx.config.review
  let cd = cooldown(ctx)
  // deterministic checks
  let _ =
    store.update(ctx.store, fn(s, e, now) {
      let #(s, added) =
        add_findings(s, review.untouched(s, r.untouched_days, now), now, cd)
      let agents_with_open =
        state.open_items(s) |> list.map(fn(i) { i.agent }) |> list.unique
      let before = dict.size(s.findings)
      let s =
        list.fold(dict.keys(s.agents), s, fn(acc, agent_id) {
          case list.contains(agents_with_open, agent_id) {
            True -> check_open_counts(ctx, acc, agent_id, now)
            False ->
              state.resolve_agent_findings(
                acc,
                agent_id,
                model.TooManyOpen,
                now,
              )
          }
        })
      case added > 0 || dict.size(s.findings) != before {
        True -> store.Changed(s, e, [store.Publish], Nil)
        False -> store.NoChange(Nil)
      }
    })
  case ctx.ask {
    None -> Nil
    Some(ask) -> {
      let now = sys.now_ms()
      // retry items whose write-time review failed
      let unreviewed =
        store.read(ctx.store, fn(s, _) {
          state.open_items(s)
          |> list.filter(fn(i) {
            option.is_none(i.reviewed_at) && i.created_at < now - 60_000
          })
          |> list.take(10)
          |> list.map(fn(i) { i.id })
        })
      list.each(unreviewed, review_item(ctx, _))
      // idle agents with activity since their last sweep
      let idle_ms = state.hours(r.sweep_idle_hours)
      let requests =
        store.read(ctx.store, fn(s, e) {
          dict.values(s.agents)
          |> list.filter_map(fn(agent) {
            let items = state.items_of(s, agent.id)
            let newest =
              list.fold(items, 0, fn(acc, i) { int.max(acc, i.updated_at) })
            let swept =
              dict.get(e.swept, agent.id)
              |> option.from_result
              |> option.unwrap(0)
            case newest > 0 && newest < now - idle_ms && swept < newest {
              True ->
                review.sweep_request(s, agent.id, now) |> option.to_result(Nil)
              False -> Error(Nil)
            }
          })
        })
      list.each(requests, fn(req) {
        let request_text =
          jev.request_json(
            ctx.config.decision_model.model,
            req.state,
            req.questions,
          )
          |> json.to_string
        let started = sys.now_ms()
        let result = ask(req.state, req.questions)
        let latency = sys.now_ms() - started
        let _ =
          store.update(ctx.store, fn(s, e, now) {
            let e = mark_swept(e, req.agent, now)
            case result {
              Ok(resp) -> {
                let #(s, judgment) =
                  state.add_judgment(
                    s,
                    now,
                    "sweep",
                    None,
                    request_text,
                    Some(resp.raw),
                    latency,
                    resp.input_tokens,
                    resp.output_tokens,
                    None,
                  )
                let findings =
                  review.interpret_sweep(
                    req,
                    resp.answers,
                    r.thresholds,
                    judgment,
                  )
                let #(s, _) = add_findings(s, findings, now, cd)
                store.Changed(s, e, [store.Publish], Nil)
              }
              Error(reason) -> {
                let #(s, _) =
                  state.add_judgment(
                    s,
                    now,
                    "sweep",
                    None,
                    request_text,
                    None,
                    latency,
                    0,
                    0,
                    Some(reason),
                  )
                store.Changed(s, e, [], Nil)
              }
            }
          })
        Nil
      })
    }
  }
}

fn mark_swept(
  e: ephemeral.Ephemeral,
  agent_id: Int,
  now: Int,
) -> ephemeral.Ephemeral {
  ephemeral.Ephemeral(..e, swept: dict.insert(e.swept, agent_id, now))
}
