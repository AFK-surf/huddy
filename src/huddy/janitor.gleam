//// Timers: review sweeps, decision e-mails, retention pruning and daily
//// backups. Heavy work runs in short-lived processes so timers stay on time.

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import huddy/ctx.{type Ctx}
import huddy/fmt
import huddy/model
import huddy/reviewer
import huddy/state
import huddy/store
import huddy/sys
import logging

pub type Msg {
  Sweep
  Minute
  Hourly
}

type Self {
  Self(ctx: Ctx, subject: Subject(Msg), last_daily: String)
}

pub fn start(ctx: Ctx) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.send_after(subject, sweep_interval(ctx), Sweep)
    process.send_after(subject, 60_000, Minute)
    process.send_after(subject, 5000, Hourly)
    actor.initialised(Self(ctx:, subject:, last_daily: ""))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn sweep_interval(ctx: Ctx) -> Int {
  ctx.config.review.sweep_interval_minutes * 60_000
}

fn handle(self: Self, msg: Msg) -> actor.Next(Self, Msg) {
  let ctx = self.ctx
  case msg {
    Sweep -> {
      process.send_after(self.subject, sweep_interval(ctx), Sweep)
      process.spawn_unlinked(fn() { reviewer.sweep(ctx) })
      actor.continue(self)
    }
    Minute -> {
      process.send_after(self.subject, 60_000, Minute)
      process.spawn_unlinked(fn() { email_decisions(ctx) })
      actor.continue(self)
    }
    Hourly -> {
      process.send_after(self.subject, 3_600_000, Hourly)
      let today = sys.utc_date_compact(sys.now_ms())
      case today == self.last_daily {
        True -> actor.continue(self)
        False -> {
          daily(ctx)
          actor.continue(Self(..self, last_daily: today))
        }
      }
    }
  }
}

/// Prune by retention, then write today's backup.
pub fn daily(ctx: Ctx) -> Nil {
  let r = ctx.config.retention
  let policy =
    state.RetentionPolicy(
      closed_items_days: r.closed_items_days,
      events_days: r.events_days,
      judgment_detail_days: r.judgment_detail_days,
      judgments_days: r.judgments_days,
    )
  let _ =
    store.update(ctx.store, fn(s, e, now) {
      store.Changed(state.prune(s, policy, now), e, [store.Publish], Nil)
    })
  store.request_backup(ctx.store)
}

/// E-mail owners about blocking decisions still unseen after the delay
/// (and non-blocking ones when configured). Each decision is mailed once; it
/// is marked before sending so a crash can't produce duplicates.
pub fn email_decisions(ctx: Ctx) -> Nil {
  let n = ctx.config.notify
  let after = n.email_blocking_after_minutes * 60_000
  let due =
    store.update(ctx.store, fn(s, e, now) {
      let candidates =
        state.open_items(s)
        |> list.filter(fn(i) {
          i.kind == model.Decision
          && { i.blocking || n.email_non_blocking }
          && option.is_none(i.seen_by)
          && option.is_none(i.owner_emailed_at)
          && option.is_none(i.hidden_by)
          && i.created_at < now - after
        })
        |> list.filter_map(fn(i) {
          use agent <- result.try(dict.get(s.agents, i.agent))
          use owner <- result.try(dict.get(s.users, agent.owner))
          case owner.notify_email {
            True -> Ok(#(i, owner.email, state.agent_label(s, i.agent)))
            False -> Error(Nil)
          }
        })
      case candidates {
        [] -> store.NoChange([])
        _ -> {
          let s =
            list.fold(candidates, s, fn(acc, c) { state.mark_emailed(acc, { c.0 }.id, now) })
          store.Changed(s, e, [], candidates)
        }
      }
    })
  case due {
    Ok(list) ->
      list.each(list, fn(c) {
        let #(item, email, label) = c
        ctx.send_email(email, decision_subject(item, label), decision_body(ctx, item, label))
      })
    Error(e) -> logging.log(logging.Error, "decision e-mails: " <> e)
  }
}

fn decision_subject(item: model.Item, label: String) -> String {
  case item.blocking {
    True -> "[Huddy] BLOCKED · " <> label <> ": " <> fmt.clip(item.title, 80)
    False -> "[Huddy] Decision · " <> label <> ": " <> fmt.clip(item.title, 80)
  }
}

fn decision_body(ctx: Ctx, item: model.Item, label: String) -> String {
  let lines = [
    case item.blocking {
      True -> label <> " is blocked, waiting for you on a decision:"
      False -> label <> " would like you to look at a decision:"
    },
    "",
    "  " <> item.title,
  ]
  let detail = case item.detail {
    "" -> []
    d -> ["", d]
  }
  let options = case item.options {
    [] -> []
    opts -> ["", "Options: " <> string.join(opts, " · ")]
  }
  let footer = [
    "",
    "Answer the agent in its own session; it will mark the decision resolved.",
    "Mark it seen on the board to stop reminders: "
      <> ctx.config.base_url
      <> "/#"
      <> model.item_ref(item.id),
  ]
  list.flatten([lines, detail, options, footer]) |> string.join("\n")
}
