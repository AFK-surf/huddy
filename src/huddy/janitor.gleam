//// Timers: review sweeps, retention pruning and daily backups. Heavy work
//// runs in short-lived processes so timers stay on time.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import huddy/ctx.{type Ctx}
import huddy/reviewer
import huddy/state
import huddy/store
import huddy/sys

pub type Msg {
  Sweep
  Hourly
}

type Self {
  Self(ctx: Ctx, subject: Subject(Msg), last_daily: String)
}

pub fn start(ctx: Ctx) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.send_after(subject, sweep_interval(ctx), Sweep)
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
