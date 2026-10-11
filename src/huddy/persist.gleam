//// The single JSON state file: loading (with format upgrades and integrity
//// checks), atomic writes, and daily backups. The file and the backups live
//// on local disk or in S3 (see `huddy/blob`).
////
//// Atomicity: on disk, every write goes to `<path>.tmp` in the same
//// directory, is fsynced, then renamed over `<path>` (see
//// `huddy_ffi:atomic_write/2`). In S3, every write is a single PUT, which
//// replaces the object atomically. Either way the stored file is always one
//// complete snapshot.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import huddy/blob.{type Location}
import huddy/codec
import huddy/model.{type State}
import huddy/sys

pub fn tmp_path(path: String) -> String {
  path <> ".tmp"
}

/// Load the state file. A leftover `.tmp` is an unfinished write and is
/// deleted unread. A missing file starts an empty state, unless backups exist
/// (then the file was lost, and silently starting empty would drop data).
/// An undecodable file is an error naming the newest backup.
pub fn load(path: Location, backup_dir: Location) -> Result(State, String) {
  let name = blob.to_string(path)
  let _ = blob.discard_partial(path)
  case blob.read(path) {
    Error("enoent") ->
      case newest_backup(backup_dir) {
        Ok(Some(backup)) ->
          Error(
            "state file "
            <> name
            <> " is missing but backups exist; restore one (newest: "
            <> backup
            <> ") or move the backups away to start empty",
          )
        Ok(None) -> Ok(model.empty_state())
        Error(reason) ->
          Error(
            "state file "
            <> name
            <> " is missing and the backups cannot be listed: "
            <> reason,
          )
      }
    Error(reason) -> Error("cannot read " <> name <> ": " <> reason)
    Ok(bits) ->
      decode_file(bits, name)
      |> result.map_error(fn(reason) {
        reason
        <> case newest_backup(backup_dir) {
          Ok(Some(backup)) -> "\nnewest backup: " <> backup
          _ -> ""
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

/// Write a complete snapshot atomically; returns its size in bytes.
pub fn write(path: Location, state: State, now: Int) -> Result(Int, String) {
  use bits <- result.try(sys.rescue(fn() { encode(state, now) }))
  use _ <- result.try(blob.write(path, bits))
  Ok(bit_array.byte_size(bits))
}

/// Write today's backup (same atomic procedure) and prune old ones.
pub fn backup(
  backup_dir: Location,
  keep: Int,
  state: State,
  now: Int,
) -> Result(String, String) {
  use _ <- result.try(blob.ensure_dir(backup_dir))
  let file =
    blob.child(backup_dir, "huddy-" <> sys.utc_date_compact(now) <> ".json")
  use _ <- result.try(write(file, state, now))
  let _ = prune_backups(backup_dir, keep)
  Ok(blob.to_string(file))
}

fn backups(backup_dir: Location) -> Result(List(String), String) {
  use names <- result.map(blob.list_dir(backup_dir))
  names
  |> list.filter(fn(name) {
    string.starts_with(name, "huddy-") && string.ends_with(name, ".json")
  })
  |> list.sort(string.compare)
}

pub fn newest_backup(backup_dir: Location) -> Result(Option(String), String) {
  use names <- result.map(backups(backup_dir))
  case list.last(names) {
    Ok(name) -> Some(blob.to_string(blob.child(backup_dir, name)))
    Error(_) -> None
  }
}

fn prune_backups(backup_dir: Location, keep: Int) -> Nil {
  let all = backups(backup_dir) |> result.unwrap([])
  let excess = list.length(all) - int.max(keep, 1)
  all
  |> list.take(int.max(excess, 0))
  |> list.each(fn(name) { blob.delete(blob.child(backup_dir, name)) })
}
