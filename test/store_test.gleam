import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import huddy/model
import huddy/state
import huddy/store
import huddy/sys
import support

fn start_store() -> store.Store {
  let cfg = support.config(support.tmp_dir(), 0)
  let assert Ok(started) =
    store.start(
      cfg,
      fn() { Ok(model.empty_state()) },
      process.new_name("store_test"),
    )
  started.data
}

/// Run `f` in a process of its own; True if that process crashed.
fn crashes(f: fn() -> a) -> Bool {
  let pid = process.spawn_unlinked(fn() { f() })
  let monitor = process.monitor(pid)
  let assert Ok(down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
  case down {
    process.ProcessDown(reason: process.Abnormal(_), ..) -> True
    _ -> False
  }
}

fn users(s: store.Store) -> Int {
  store.read(s, fn(st, _) { dict.size(st.users) })
}

pub fn crashing_closures_fail_the_caller_not_the_store_test() {
  let s = start_store()
  let assert Ok(pid) = process.subject_owner(s)
  let #(_, _) =
    store.update_lazy(s, fn(st, e, now) {
      let #(st, u) = state.create_user(st, "alice@acme.dev", now)
      store.Changed(st, e, [], #(st, u))
    })
  // More crashes than the supervisor's restart limit (3 in 5 s) would allow.
  assert crashes(fn() { store.read(s, fn(_, _) { panic as "buggy query" }) })
  assert crashes(fn() {
    store.update(s, fn(_, _, _) -> store.Change(Nil) { panic as "buggy update" })
  })
  assert crashes(fn() {
    store.update_lazy(s, fn(_, _, _) -> store.Change(Nil) {
      panic as "buggy lazy update"
    })
  })
  assert crashes(fn() {
    store.update_or_pending(s, fn(_, _, _) -> store.Change(Nil) {
      panic as "buggy update"
    })
  })
  // Same process, and the change made before the crashes is still there.
  assert process.subject_owner(s) == Ok(pid)
  assert users(s) == 1
  let assert Ok(Nil) = store.flush(s)
}

pub fn a_slow_load_does_not_hold_up_the_start_test() {
  let cfg = support.config(support.tmp_dir(), 0)
  let started_at = sys.now_ms()
  let assert Ok(started) =
    store.start(
      cfg,
      fn() {
        process.sleep(1000)
        Ok(model.empty_state())
      },
      process.new_name("store_test"),
    )
  assert sys.now_ms() - started_at < 500
  // A change sent while loading is applied once the state is in.
  let assert Ok(Nil) =
    store.update(started.data, fn(st, e, now) {
      let #(st, _) = state.create_user(st, "alice@acme.dev", now)
      store.Changed(st, e, [], Nil)
    })
  assert users(started.data) == 1
}

pub fn a_failed_load_is_retried_test() {
  let dir = support.tmp_dir()
  let cfg = support.config(dir, 0)
  let ready = dir <> "/ready"
  let assert Ok(started) =
    store.start(
      cfg,
      fn() {
        case sys.file_exists(ready) {
          True -> Ok(model.empty_state())
          False -> Error("storage is down")
        }
      },
      process.new_name("store_test"),
    )
  let s = started.data
  process.sleep(100)
  assert store.status(s) == Some("storage is down")
  support.write_file(ready, <<>>)
  // waits for the retry
  assert users(s) == 0
  assert store.status(s) == None
}
