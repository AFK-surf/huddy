//// The single JSON state file: loading (with format upgrades and integrity
//// checks), atomic writes, the single-instance lock, and daily backups.
////
//// Atomicity: every write goes to `<path>.tmp` in the same directory, is
//// fsynced, then renamed over `<path>` (see `huddy_ffi:atomic_write/2`). The
//// file on disk is therefore always one complete snapshot.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import huddy/codec
import huddy/model.{type State}
import huddy/sys

pub fn lock_path(path: String) -> String {
  path <> ".lock"
}

pub fn tmp_path(path: String) -> String {
  path <> ".tmp"
}

pub fn acquire_lock(path: String) -> Result(Nil, String) {
  sys.acquire_lock(lock_path(path))
}

pub fn release_lock(path: String) -> Nil {
  sys.release_lock(lock_path(path))
}

/// Load the state file. A leftover `.tmp` is an unfinished write and is
/// deleted unread. A missing file starts an empty state, unless backups exist
/// (then the file was lost, and silently starting empty would drop data).
/// An undecodable file is an error naming the newest backup.
pub fn load(path: String, backup_dir: String) -> Result(State, String) {
  let _ = sys.delete_file(tmp_path(path))
  case sys.read_file(path) {
    Error("enoent") ->
      case newest_backup(backup_dir) {
        Ok(backup) ->
          Error(
            "state file "
            <> path
            <> " is missing but backups exist; restore one (newest: "
            <> backup
            <> ") or move the backups away to start empty",
          )
        Error(_) -> Ok(model.empty_state())
      }
    Error(reason) -> Error("cannot read " <> path <> ": " <> reason)
    Ok(bits) ->
      decode_file(bits, path)
      |> result.map_error(fn(reason) {
        reason
        <> case newest_backup(backup_dir) {
          Ok(backup) -> "\nnewest backup: " <> backup
          Error(_) -> ""
        }
      })
  }
}

/// Decode file contents, upgrading older formats first.
pub fn decode_file(bits: BitArray, path: String) -> Result(State, String) {
  let invalid = fn(e) { "cannot decode " <> path <> ": " <> describe(e) }
  use raw <- result.try(
    json.parse_bits(bits, decode.dynamic) |> result.map_error(invalid),
  )
  use version <- result.try(
    decode.run(raw, codec.format_decoder())
    |> result.replace_error("cannot decode " <> path <> ": missing \"format\""),
  )
  use upgraded <- result.try(upgrade(raw, version))
  use state <- result.try(
    decode.run(upgraded, codec.state_decoder())
    |> result.map_error(fn(errors) {
      "cannot decode " <> path <> ": " <> describe(json.UnableToDecode(errors))
    }),
  )
  use _ <- result.try(
    codec.check_references(state)
    |> result.map_error(fn(e) {
      "integrity check failed for " <> path <> ": " <> e
    }),
  )
  Ok(state)
}

/// Upgrade steps, one per format version: each is a pure Dynamic -> Dynamic
/// transformation from version N to N+1. Format 1 is current, so there are
/// none yet.
fn upgrade(raw: Dynamic, version: Int) -> Result(Dynamic, String) {
  case int.compare(version, codec.format) {
    order.Eq -> Ok(raw)
    order.Gt ->
      Error(
        "state file has format "
        <> int.to_string(version)
        <> ", newer than this build supports ("
        <> int.to_string(codec.format)
        <> ")",
      )
    order.Lt -> Error("no upgrade path from format " <> int.to_string(version))
  }
}

fn describe(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "unexpected end of input (truncated file?)"
    json.UnexpectedByte(b) -> "invalid JSON near " <> b
    json.UnexpectedSequence(s) -> "invalid JSON near " <> s
    json.UnableToDecode(errors) ->
      errors
      |> list.take(5)
      |> list.map(fn(e) {
        let decode.DecodeError(expected:, found:, path:) = e
        string.join(path, ".")
        <> ": expected "
        <> expected
        <> ", found "
        <> found
      })
      |> string.join("; ")
  }
}

pub fn encode(state: State, now: Int) -> BitArray {
  codec.encode_state(state, now)
  |> json.to_string
  |> bit_array.from_string
}

/// Write a complete snapshot atomically.
pub fn write(path: String, state: State, now: Int) -> Result(Nil, String) {
  use bits <- result.try(sys.rescue(fn() { encode(state, now) }))
  sys.atomic_write(path, bits)
}

/// Write today's backup (same atomic procedure) and prune old ones.
pub fn backup(
  backup_dir: String,
  keep: Int,
  state: State,
  now: Int,
) -> Result(String, String) {
  use _ <- result.try(sys.ensure_dir(backup_dir))
  let file = backup_dir <> "/huddy-" <> sys.utc_date_compact(now) <> ".json"
  use _ <- result.try(write(file, state, now))
  let _ = prune_backups(backup_dir, keep)
  Ok(file)
}

fn backups(backup_dir: String) -> List(String) {
  sys.list_dir(backup_dir)
  |> result.unwrap([])
  |> list.filter(fn(name) {
    string.starts_with(name, "huddy-") && string.ends_with(name, ".json")
  })
  |> list.sort(string.compare)
}

pub fn newest_backup(backup_dir: String) -> Result(String, Nil) {
  backups(backup_dir)
  |> list.last
  |> result.map(fn(name) { backup_dir <> "/" <> name })
}

fn prune_backups(backup_dir: String, keep: Int) -> Nil {
  let all = backups(backup_dir)
  let excess = list.length(all) - int.max(keep, 1)
  all
  |> list.take(int.max(excess, 0))
  |> list.each(fn(name) { sys.delete_file(backup_dir <> "/" <> name) })
}
