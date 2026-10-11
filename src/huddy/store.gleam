//// The store actor: owns the canonical `State` (and in-memory `Ephemeral`
//// data), is the only writer of the state file, batches writes (group
//// commit), and publishes board changes to SSE subscribers.
////
//// Callers pass closures that run inside the actor:
//// - `read` runs a query against the current state;
//// - `update` applies a change and replies once the snapshot containing it
////   is on disk (durable);
//// - `update_lazy` applies a best-effort change and replies immediately;
////   it is flushed with the next batch or within `idle_flush_seconds`.
////
//// A closure that crashes does not crash the actor: the exception is sent
//// back and raised again in the caller, so a bug in one request fails that
//// request instead of restarting the store (which would drop un-flushed
//// changes, in-memory data and every live page's subscription).

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import huddy/config.{type Config}
import huddy/ephemeral.{type Ephemeral}
import huddy/model.{type State}
import huddy/persist
import huddy/rank
import huddy/state
import huddy/sys
import logging

pub type Store =
  Subject(Msg)

/// Messages delivered to SSE subscribers.
pub type BoardEvent {
  BoardChanged
  /// A JSON payload for the browser's `notify` event.
  Notify(payload: String)
  /// Used internally by SSE connections (keep-alive and coalesced render);
  /// the store never sends these.
  SseTick
  SseRender
}

pub type Effect {
  /// The display may have changed.
  Publish
  /// A decision was posted or became blocking: notify its owner.
  NotifyDecision(item_id: Int)
}

/// What an update did, as seen by the actor.
pub opaque type Applied {
  Applied(
    state: Option(State),
    eph: Option(Ephemeral),
    effects: List(Effect),
    reply: fn(Result(Nil, String)) -> Nil,
  )
}

/// The result of an update closure.
pub type Change(a) {
  /// The durable state changed (and maybe ephemeral data too).
  Changed(state: State, eph: Ephemeral, effects: List(Effect), value: a)
  /// Only ephemeral data changed; nothing to write.
  EphemeralChanged(eph: Ephemeral, value: a)
  /// Nothing changed.
  NoChange(value: a)
}

pub opaque type Msg {
  Read(run: fn(State, Ephemeral) -> Nil)
  Update(run: fn(State, Ephemeral, Int) -> Applied, durable: Bool)
  Flush
  /// the snapshot's size in bytes, or why the write failed
  Written(result: Result(Int, String))
  Subscribe(subject: Subject(BoardEvent), user: Int)
  Unsubscribe(subject: Subject(BoardEvent))
  Rerank
  GetView(filters: rank.Filters, reply: Subject(Result(rank.View, sys.Crash)))
  Backup
  Expire
  GetStatus(reply: Subject(Option(String)))
}

type Waiting {
  Waiting(reply: fn(Result(Nil, String)) -> Nil, effects: List(Effect))
}

type Self {
  Self(
    config: Config,
    subject: Subject(Msg),
    state: State,
    eph: Ephemeral,
    dirty: Bool,
    writing: Bool,
    /// durable callers waiting for the next flush
    pending: List(Waiting),
    /// durable callers waiting for the flush in progress
    inflight: List(Waiting),
    flush_at: Option(Int),
    failures: Int,
    storage_error: Option(String),
    subscribers: List(#(Subject(BoardEvent), Int)),
    visible: rank.Visible,
    size_warned_at: Int,
  )
}

/// Start the store under `name`, so its subject survives restarts.
pub fn start(
  config: Config,
  initial: State,
  name: process.Name(Msg),
) -> actor.StartResult(Store) {
  actor.new_with_initialiser(5000, fn(subject) {
    let self =
      Self(
        config:,
        subject:,
        state: initial,
        eph: ephemeral.new(),
        dirty: False,
        writing: False,
        pending: [],
        inflight: [],
        flush_at: None,
        failures: 0,
        storage_error: None,
        subscribers: [],
        visible: rank.no_visible(),
        size_warned_at: 0,
      )
    process.send_after(
      subject,
      config.display.rerank_interval_seconds * 1000,
      Rerank,
    )
    process.send_after(subject, 60_000, Expire)
    actor.initialised(self)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

// --- client API ----------------------------------------------------------------

const call_timeout = 15_000

/// Run a query against the current state.
pub fn read(store: Store, query: fn(State, Ephemeral) -> a) -> a {
  let reply = process.new_subject()
  process.send(
    store,
    Read(fn(s, e) { process.send(reply, sys.capture(fn() { query(s, e) })) }),
  )
  case process.receive(reply, call_timeout) {
    Ok(Ok(value)) -> value
    Ok(Error(crash)) -> sys.reraise(crash)
    Error(_) -> panic as "store: read timed out"
  }
}

/// Apply a change; reply once it is durable on disk. Returns
/// `Error("storage: …")` if the write failed (the change is still in memory
/// and will be retried).
pub fn update(
  store: Store,
  change: fn(State, Ephemeral, Int) -> Change(a),
) -> Result(a, String) {
  send_update(store, change, True)
}

/// Like `update`, but the value comes back even if the write failed:
/// `Ok(#(value, True))` once the change is on disk, `Ok(#(value, False))` if
/// the write failed for now (the change is in memory and retried, so it
/// will become durable unless the node stops first). `Error` only if the
/// store did not answer in time, when the outcome is unknown.
pub fn update_or_pending(
  store: Store,
  change: fn(State, Ephemeral, Int) -> Change(a),
) -> Result(#(a, Bool), String) {
  let reply = process.new_subject()
  let run = fn(s, e, now) {
    case sys.capture(fn() { change(s, e, now) }) {
      Ok(Changed(state:, eph:, effects:, value:)) ->
        Applied(Some(state), Some(eph), effects, fn(r) {
          process.send(reply, Ok(#(value, result.is_ok(r))))
        })
      Ok(EphemeralChanged(eph:, value:)) ->
        Applied(None, Some(eph), [], fn(_) {
          process.send(reply, Ok(#(value, True)))
        })
      Ok(NoChange(value:)) ->
        Applied(None, None, [], fn(_) {
          process.send(reply, Ok(#(value, True)))
        })
      Error(crash) -> crashed(reply, crash)
    }
  }
  process.send(store, Update(run, True))
  case process.receive(reply, call_timeout) {
    Ok(Ok(value)) -> Ok(value)
    Ok(Error(crash)) -> sys.reraise(crash)
    Error(_) -> Error("storage: timed out waiting for the write")
  }
}

/// Apply a best-effort change and reply immediately.
pub fn update_lazy(
  store: Store,
  change: fn(State, Ephemeral, Int) -> Change(a),
) -> a {
  let assert Ok(value) = send_update(store, change, False)
  value
}

fn send_update(
  store: Store,
  change: fn(State, Ephemeral, Int) -> Change(a),
  durable: Bool,
) -> Result(a, String) {
  let reply = process.new_subject()
  let run = fn(s, e, now) {
    case sys.capture(fn() { change(s, e, now) }) {
      Ok(Changed(state:, eph:, effects:, value:)) ->
        Applied(Some(state), Some(eph), effects, fn(r) {
          process.send(reply, Ok(result.map(r, fn(_) { value })))
        })
      Ok(EphemeralChanged(eph:, value:)) ->
        Applied(None, Some(eph), [], fn(_) {
          process.send(reply, Ok(Ok(value)))
        })
      Ok(NoChange(value:)) ->
        Applied(None, None, [], fn(_) { process.send(reply, Ok(Ok(value))) })
      Error(crash) -> crashed(reply, crash)
    }
  }
  process.send(store, Update(run, durable))
  case process.receive(reply, call_timeout) {
    Ok(Ok(value)) -> value
    Ok(Error(crash)) -> sys.reraise(crash)
    Error(_) -> Error("storage: timed out waiting for the write")
  }
}

/// An update whose closure crashed: nothing changes, and the caller gets
/// the crash to raise again.
fn crashed(reply: Subject(Result(a, sys.Crash)), crash: sys.Crash) -> Applied {
  Applied(None, None, [], fn(_) { process.send(reply, Error(crash)) })
}

pub fn subscribe(store: Store, subject: Subject(BoardEvent), user: Int) -> Nil {
  process.send(store, Subscribe(subject, user))
}

pub fn unsubscribe(store: Store, subject: Subject(BoardEvent)) -> Nil {
  process.send(store, Unsubscribe(subject))
}

pub fn view(store: Store, filters: rank.Filters) -> rank.View {
  let reply = process.new_subject()
  process.send(store, GetView(filters, reply))
  case process.receive(reply, call_timeout) {
    Ok(Ok(v)) -> v
    Ok(Error(crash)) -> sys.reraise(crash)
    Error(_) -> panic as "store: view timed out"
  }
}

pub fn request_backup(store: Store) -> Nil {
  process.send(store, Backup)
}

/// Force a flush now (used by tests and shutdown).
pub fn flush(store: Store) -> Result(Nil, String) {
  update(store, fn(s, e, _) { Changed(s, e, [], Nil) })
}

// --- actor ---------------------------------------------------------------------

fn handle(self: Self, msg: Msg) -> actor.Next(Self, Msg) {
  let now = sys.now_ms()
  case msg {
    Read(run) -> {
      run(self.state, self.eph)
      actor.continue(self)
    }

    Update(run, durable) -> {
      let Applied(state: new_state, eph: new_eph, effects:, reply:) =
        run(self.state, self.eph, now)
      let self = case new_eph {
        Some(e) -> Self(..self, eph: e)
        None -> self
      }
      case new_state {
        None -> {
          reply(Ok(Nil))
          actor.continue(self)
        }
        Some(s) -> {
          let self = Self(..self, state: s, dirty: True)
          case durable {
            True -> {
              let self =
                Self(..self, pending: [Waiting(reply, effects), ..self.pending])
              actor.continue(schedule(self, self.config.storage.flush_ms, now))
            }
            False -> {
              reply(Ok(Nil))
              let self = run_effects(self, effects)
              actor.continue(schedule(
                self,
                self.config.storage.idle_flush_seconds * 1000,
                now,
              ))
            }
          }
        }
      }
    }

    Flush -> {
      let self = Self(..self, flush_at: None)
      case self.writing, self.dirty {
        False, True -> actor.continue(start_write(self, now))
        _, _ -> actor.continue(self)
      }
    }

    Written(result) -> {
      let waiting = list.reverse(self.inflight)
      list.each(waiting, fn(w) {
        w.reply(
          result
          |> result.replace(Nil)
          |> result.map_error(fn(e) { "storage: " <> e }),
        )
      })
      let self = Self(..self, writing: False, inflight: [])
      let self =
        list.fold(waiting, self, fn(acc, w) { run_effects(acc, w.effects) })
      case result {
        Ok(size) -> {
          let self = case self.storage_error {
            Some(_) -> {
              logging.log(logging.Notice, "storage: write succeeded again")
              broadcast(
                Self(..self, storage_error: None, failures: 0),
                BoardChanged,
              )
            }
            None -> Self(..self, failures: 0)
          }
          let self = check_size(self, size, now)
          case self.dirty {
            True ->
              actor.continue(schedule(self, self.config.storage.flush_ms, now))
            False -> actor.continue(self)
          }
        }
        Error(reason) -> {
          logging.log(logging.Error, "storage: write failed: " <> reason)
          let failures = self.failures + 1
          let delay = int.min(30_000, 500 * pow2(failures))
          let self =
            Self(..self, dirty: True, failures:, storage_error: Some(reason))
          let self = broadcast(self, BoardChanged)
          actor.continue(schedule(self, delay, now))
        }
      }
    }

    Subscribe(subject, user) ->
      actor.continue(
        Self(..self, subscribers: [#(subject, user), ..self.subscribers]),
      )

    Unsubscribe(subject) ->
      actor.continue(
        Self(
          ..self,
          subscribers: list.filter(self.subscribers, fn(s) { s.0 != subject }),
        ),
      )

    Rerank -> {
      process.send_after(
        self.subject,
        self.config.display.rerank_interval_seconds * 1000,
        Rerank,
      )
      // drop subscribers whose process has gone away
      let alive =
        list.filter(self.subscribers, fn(s) {
          case process.subject_owner(s.0) {
            Ok(pid) -> process.is_alive(pid)
            Error(_) -> False
          }
        })
      let self = Self(..self, subscribers: alive)
      case sys.capture(fn() { compute_view(self, rank.no_filters(), now) }) {
        Ok(#(_, visible)) ->
          actor.continue(broadcast(Self(..self, visible:), BoardChanged))
        Error(crash) -> {
          logging.log(
            logging.Error,
            "store: ranking failed: " <> sys.describe_crash(crash),
          )
          actor.continue(self)
        }
      }
    }

    GetView(filters, reply) ->
      case sys.capture(fn() { compute_view(self, filters, now) }) {
        Ok(#(view, visible)) -> {
          process.send(reply, Ok(view))
          case rank.is_default(filters) {
            True -> actor.continue(Self(..self, visible:))
            False -> actor.continue(self)
          }
        }
        Error(crash) -> {
          process.send(reply, Error(crash))
          actor.continue(self)
        }
      }

    Backup -> {
      let snapshot = self.state
      let storage = self.config.storage
      process.spawn_unlinked(fn() {
        case
          persist.backup(storage.backup_dir, storage.backup_keep, snapshot, now)
        {
          Ok(file) -> logging.log(logging.Info, "backup written: " <> file)
          Error(e) -> logging.log(logging.Error, "backup failed: " <> e)
        }
      })
      actor.continue(self)
    }

    GetStatus(reply) -> {
      process.send(reply, self.storage_error)
      actor.continue(self)
    }

    Expire -> {
      process.send_after(self.subject, 60_000, Expire)
      actor.continue(Self(..self, eph: ephemeral.expire(self.eph, now)))
    }
  }
}

fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * pow2(n - 1)
  }
}

fn compute_view(
  self: Self,
  filters: rank.Filters,
  now: Int,
) -> #(rank.View, rank.Visible) {
  let previous = case rank.is_default(filters) {
    True -> self.visible
    False -> rank.no_visible()
  }
  rank.compute(
    self.state,
    self.config.display,
    self.config.review.thresholds.stale,
    filters,
    previous,
    now,
  )
}

/// Ensure a Flush arrives within `delay` ms.
fn schedule(self: Self, delay: Int, now: Int) -> Self {
  let due = now + delay
  case self.flush_at {
    Some(at) if at <= due -> self
    _ -> {
      process.send_after(self.subject, delay, Flush)
      Self(..self, flush_at: Some(due))
    }
  }
}

fn start_write(self: Self, now: Int) -> Self {
  let snapshot = model.State(..self.state, saved_at: now)
  let path = self.config.storage.path
  let subject = self.subject
  process.spawn(fn() {
    let result = case sys.rescue(fn() { persist.write(path, snapshot, now) }) {
      Ok(r) -> r
      Error(e) -> Error(e)
    }
    process.send(subject, Written(result))
  })
  Self(..self, writing: True, dirty: False, inflight: self.pending, pending: [])
}

fn check_size(self: Self, size: Int, now: Int) -> Self {
  let limit = self.config.storage.warn_mb * 1_048_576
  case size > limit && now - self.size_warned_at > 3_600_000 {
    True -> {
      logging.log(
        logging.Warning,
        "storage: state file is "
          <> int.to_string(size / 1_048_576)
          <> " MB (warn_mb = "
          <> int.to_string(self.config.storage.warn_mb)
          <> "); consider shorter retention",
      )
      Self(..self, size_warned_at: now)
    }
    False -> self
  }
}

fn run_effects(self: Self, effects: List(Effect)) -> Self {
  list.fold(list.unique(effects), self, fn(acc, effect) {
    case effect {
      Publish -> broadcast(acc, BoardChanged)
      NotifyDecision(item_id) -> notify_decision(acc, item_id)
    }
  })
}

fn broadcast(self: Self, event: BoardEvent) -> Self {
  list.each(self.subscribers, fn(s) { process.send(s.0, event) })
  self
}

/// Browser notification for the decision's owner (§4.3): blocking always,
/// non-blocking only if the owner opted in.
fn notify_decision(self: Self, item_id: Int) -> Self {
  case self.config.notify.browser, state.get_item(self.state, item_id) {
    True, Some(item) if item.kind == model.Decision -> {
      let owner = case dict.get(self.state.agents, item.agent) {
        Ok(a) -> Some(a.owner)
        Error(_) -> None
      }
      case owner {
        Some(owner_id) -> {
          let wants = case state.user(self.state, owner_id) {
            Some(u) -> item.blocking || u.notify_browser_non_blocking
            None -> False
          }
          case wants {
            True -> {
              let label = state.agent_label(self.state, item.agent)
              let payload =
                json.object([
                  #("tag", json.string("huddy-d" <> int.to_string(item.id))),
                  #(
                    "title",
                    json.string(case item.blocking {
                      True -> "BLOCKED · " <> label
                      False -> "Decision · " <> label
                    }),
                  ),
                  #("body", json.string(item.title)),
                  #(
                    "count",
                    json.int(rank.unseen_decisions_for(self.state, owner_id)),
                  ),
                ])
                |> json.to_string
              list.each(self.subscribers, fn(s) {
                case s.1 == owner_id {
                  True -> process.send(s.0, Notify(payload))
                  False -> Nil
                }
              })
              self
            }
            False -> self
          }
        }
        None -> self
      }
    }
    _, _ -> self
  }
}

/// Storage status for the banner.
pub fn status(store: Store) -> Option(String) {
  let reply = process.new_subject()
  process.send(store, GetStatus(reply))
  process.receive(reply, call_timeout) |> result.unwrap(None)
}
