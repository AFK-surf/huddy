import gleam/bit_array
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import huddy/codec
import huddy/model
import huddy/persist
import huddy/state
import huddy/sys
import support

fn sample_state() -> model.State {
  let now = 1_791_622_800_000
  let #(s, a, b) = support.two_agents(now)
  let #(s, goal) = state.create_item(s, a, support.goal("Ship OAuth"), now)
  let #(s, task) = state.create_item(s, b, support.task("Deflake tests"), now)
  let #(s, _) =
    state.add_finding(
      s,
      state.NewFinding(
        agent: a,
        item: Some(goal.id),
        item_version: Some(1),
        related_item: Some(task.id),
        kind: model.Overlap,
        confidence: Some(0.8),
        message: "overlaps \"quoted\" ✓",
        judgment: None,
      ),
      now,
      0,
    )
  let #(s, _) =
    state.add_judgment(
      s,
      now,
      "write",
      Some(goal.id),
      "{\"q\":1}",
      Some("{}"),
      12,
      100,
      2,
      None,
    )
  let #(s, _) =
    state.create_link(
      s,
      1,
      sys.sha256_hex("secret"),
      "laptop",
      Some("codex"),
      None,
      "huddy:read",
      now,
    )
  s
}

fn encoded(s: model.State) -> String {
  codec.encode_state(s, 0) |> json.to_string
}

pub fn round_trip_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  let s = sample_state()
  let assert Ok(_) = persist.write(path, s, 42)
  let assert Ok(loaded) = persist.load(path, dir <> "/backups")
  assert encoded(loaded) == encoded(s)
  assert loaded.saved_at == 42
}

pub fn retired_findings_are_dropped_on_load_test() {
  let s = sample_state()
  let text =
    encoded(s)
    |> string.replace("\"kind\":\"overlap\"", "\"kind\":\"injection\"")
    |> string.replace(
      "\"closed_at\":null}",
      "\"closed_at\":null,\"flagged\":true}",
    )
  assert string.contains(text, "\"injection\"")
  let assert Ok(loaded) = json.parse(text, codec.state_decoder())
  assert dict.is_empty(loaded.findings)
  assert dict.size(loaded.items) == dict.size(s.items)
}

pub fn missing_file_starts_empty_test() {
  let dir = support.tmp_dir()
  let assert Ok(s) = persist.load(dir <> "/huddy.json", dir <> "/backups")
  assert encoded(s) == encoded(model.empty_state())
}

pub fn leftover_tmp_is_ignored_and_removed_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  let assert Ok(_) = persist.write(path, sample_state(), 1)
  // a crash mid-write leaves a partial temp file next to the real one
  support.write_file(
    persist.tmp_path(path),
    bit_array.from_string("{\"format\":1,\"next"),
  )
  let assert Ok(loaded) = persist.load(path, dir <> "/backups")
  assert encoded(loaded) == encoded(sample_state())
  assert !sys.file_exists(persist.tmp_path(path))
}

pub fn truncated_file_refuses_and_names_backup_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  let backups = dir <> "/backups"
  let assert Ok(backup) =
    persist.backup(backups, 3, sample_state(), 1_791_622_800_000)
  support.write_file(path, bit_array.from_string("{\"format\":1,\"saved_at\":"))
  let assert Error(message) = persist.load(path, backups)
  assert string.contains(message, "cannot decode")
  assert string.contains(message, backup)
}

pub fn missing_file_with_backups_refuses_test() {
  let dir = support.tmp_dir()
  let backups = dir <> "/backups"
  let assert Ok(_) =
    persist.backup(backups, 3, sample_state(), 1_791_622_800_000)
  let assert Error(message) = persist.load(dir <> "/huddy.json", backups)
  assert string.contains(message, "missing but backups exist")
}

pub fn newer_format_refuses_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  support.write_file(path, bit_array.from_string("{\"format\": 99}"))
  let assert Error(message) = persist.load(path, dir <> "/backups")
  assert string.contains(message, "newer than this build")
}

pub fn dangling_reference_refuses_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  let s = sample_state()
  let broken = model.State(..s, users: s.users |> dict_drop_all)
  let assert Ok(_) = persist.write(path, broken, 1)
  let assert Error(message) = persist.load(path, dir <> "/backups")
  assert string.contains(message, "dangling reference")
}

fn dict_drop_all(d: dict.Dict(Int, model.User)) -> dict.Dict(Int, model.User) {
  dict.drop(d, dict.keys(d))
}

pub fn lock_is_exclusive_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  // pid 1 always exists: the lock is held by a live process
  support.write_file(persist.lock_path(path), bit_array.from_string("1"))
  let assert Error(message) = persist.acquire_lock(path)
  assert string.contains(message, "pid 1")
}

pub fn stale_lock_is_replaced_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  support.write_file(
    persist.lock_path(path),
    bit_array.from_string("999999999"),
  )
  let assert Ok(_) = persist.acquire_lock(path)
  persist.release_lock(path)
  assert !sys.file_exists(persist.lock_path(path))
}

@external(erlang, "huddy_ffi", "lock_identity")
fn lock_identity(pid: String) -> String

pub fn lock_held_by_live_process_is_exclusive_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  // pid 1 with its real start time and the current boot id: still running
  support.write_file(
    persist.lock_path(path),
    bit_array.from_string(lock_identity("1")),
  )
  let assert Error(message) = persist.acquire_lock(path)
  assert string.contains(message, "pid 1")
}

pub fn lock_with_reused_pid_is_replaced_test() {
  let dir = support.tmp_dir()
  let path = dir <> "/huddy.json"
  // pid 1 exists, but it is not the process that wrote the lock (different
  // start time and boot), as after a reboot or container restart
  support.write_file(
    persist.lock_path(path),
    bit_array.from_string("1 0 00000000-0000-0000-0000-000000000000"),
  )
  let assert Ok(_) = persist.acquire_lock(path)
  persist.release_lock(path)
}

pub fn backups_are_pruned_test() {
  let dir = support.tmp_dir()
  let backups = dir <> "/backups"
  let day = 86_400_000
  let start = 1_791_622_800_000
  let _ = persist.backup(backups, 2, sample_state(), start)
  let _ = persist.backup(backups, 2, sample_state(), start + day)
  let assert Ok(newest) =
    persist.backup(backups, 2, sample_state(), start + 2 * day)
  let assert Ok(names) = sys.list_dir(backups)
  assert list.length(names) == 2
  let assert Ok(found) = persist.newest_backup(backups)
  assert found == newest
}
