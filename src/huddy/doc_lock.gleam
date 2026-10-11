//// Serializes changes to each document. Every document being changed has
//// exactly one actor, and that actor runs the document's operations
//// (uploading a new version, deleting it) one at a time, in arrival order,
//// including the file writes. One named registry actor routes operations to
//// the document's actor, starting it on demand and stopping it once it has
//// been idle for a while. Operations on different documents run in
//// parallel.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import huddy/sys

pub type Locks =
  Subject(Msg)

pub opaque type Msg {
  Run(doc: Int, job: fn() -> Nil)
  /// A document's actor has run `done` jobs and been idle since.
  Idle(doc: Int, done: Int)
}

type Worker {
  Worker(subject: Subject(WorkerMsg), sent: Int)
}

type Registry {
  Registry(self: Subject(Msg), workers: Dict(Int, Worker))
}

type WorkerMsg {
  Job(run: fn() -> Nil)
  /// sent to itself after a job; idle if no job ran since
  Check(done: Int)
  Stop
}

type WorkerState {
  WorkerState(
    registry: Subject(Msg),
    self: Subject(WorkerMsg),
    doc: Int,
    done: Int,
  )
}

/// A document's actor stops after this long without work.
const idle_ms = 30_000

/// Start the registry under `name`, so its subject survives restarts.
pub fn start(name: process.Name(Msg)) -> actor.StartResult(Locks) {
  actor.new_with_initialiser(1000, fn(self) {
    actor.initialised(Registry(self:, workers: dict.new()))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

/// Why `run` returned no result.
pub type Failure {
  /// Earlier changes to the document took longer than the caller would
  /// wait, so the work never started: nothing happened.
  NotStarted
  /// The work crashed part-way.
  Crashed(String)
  /// The work started but did not finish in time; it may still complete.
  Unfinished
}

/// How long a job that is about to start waits for its caller to confirm
/// it still wants the result.
const confirm_ms = 1000

/// How long the caller waits for work that has started.
const work_timeout_ms = 600_000

/// Run `work` on document `doc`'s actor, after every operation on that
/// document sent before it. The caller waits up to `timeout_ms` for the work
/// to start; when it is about to, caller and job shake hands, so work whose
/// caller has given up is skipped instead of applied behind its back.
pub fn run(
  locks: Locks,
  doc: Int,
  timeout_ms: Int,
  work: fn() -> a,
) -> Result(a, Failure) {
  let starting = process.new_subject()
  process.send(
    locks,
    Run(doc, fn() {
      let go = process.new_subject()
      process.send(starting, go)
      case process.receive(go, confirm_ms) {
        Ok(reply) -> process.send(reply, sys.rescue(work))
        // the caller timed out: skip the work
        Error(_) -> Nil
      }
    }),
  )
  case process.receive(starting, timeout_ms) {
    Error(_) -> Error(NotStarted)
    Ok(go) -> {
      let reply = process.new_subject()
      process.send(go, reply)
      case process.receive(reply, work_timeout_ms) {
        Ok(Ok(value)) -> Ok(value)
        Ok(Error(crash)) -> Error(Crashed(crash))
        Error(_) -> Error(Unfinished)
      }
    }
  }
}

/// A sentence for a failure, for tool results and pages.
pub fn describe(failure: Failure) -> String {
  case failure {
    NotStarted ->
      "Other changes to the document took too long; nothing was changed. Try again."
    Crashed(crash) -> "The change failed: " <> crash
    Unfinished ->
      "The change is taking unusually long and may still complete; check the document before retrying."
  }
}

fn handle(registry: Registry, msg: Msg) -> actor.Next(Registry, Msg) {
  case msg {
    Run(doc, job) -> {
      let worker = case dict.get(registry.workers, doc) {
        Ok(w) -> Ok(w)
        Error(_) -> start_worker(registry.self, doc)
      }
      case worker {
        Ok(w) -> {
          process.send(w.subject, Job(job))
          actor.continue(
            Registry(
              ..registry,
              workers: dict.insert(
                registry.workers,
                doc,
                Worker(..w, sent: w.sent + 1),
              ),
            ),
          )
        }
        // the caller times out
        Error(_) -> actor.continue(registry)
      }
    }
    // Stop the actor only if it has run every job sent to it; otherwise a
    // job is still queued there, and a new actor for the same document
    // would run concurrently with it.
    Idle(doc, done) ->
      case dict.get(registry.workers, doc) {
        Ok(w) if w.sent == done -> {
          process.send(w.subject, Stop)
          actor.continue(
            Registry(..registry, workers: dict.delete(registry.workers, doc)),
          )
        }
        _ -> actor.continue(registry)
      }
  }
}

/// Linked to the registry: if the registry restarts, the actors it routed
/// to go with it, so there is never more than one actor per document.
fn start_worker(registry: Subject(Msg), doc: Int) -> Result(Worker, Nil) {
  actor.new_with_initialiser(1000, fn(self) {
    actor.initialised(WorkerState(registry:, self:, doc:, done: 0))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(worker)
  |> actor.start
  |> fn(started) {
    case started {
      Ok(s) -> Ok(Worker(subject: s.data, sent: 0))
      Error(_) -> Error(Nil)
    }
  }
}

fn worker(
  state: WorkerState,
  msg: WorkerMsg,
) -> actor.Next(WorkerState, WorkerMsg) {
  case msg {
    Job(run) -> {
      run()
      let done = state.done + 1
      process.send_after(state.self, idle_ms, Check(done))
      actor.continue(WorkerState(..state, done:))
    }
    Check(done) if done == state.done -> {
      process.send(state.registry, Idle(state.doc, done))
      actor.continue(state)
    }
    Check(_) -> actor.continue(state)
    Stop -> actor.stop()
  }
}
