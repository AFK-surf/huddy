import gleam/dict
import gleam/erlang/process
import huddy/model
import huddy/state
import huddy/store
import support

fn start_store() -> store.Store {
  let cfg = support.config(support.tmp_dir(), 0)
  let assert Ok(started) =
    store.start(cfg, model.empty_state(), process.new_name("store_test"))
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
