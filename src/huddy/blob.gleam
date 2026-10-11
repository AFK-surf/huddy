//// Where the state file and its backups live: a local file or directory, or
//// an object or key prefix in S3 (or an S3-compatible store). In the
//// configuration, an `s3://bucket/key` path selects S3; anything else is a
//// local path.

import gleam/list
import gleam/result
import gleam/string
import huddy/s3
import huddy/sys

pub type Location {
  File(path: String)
  /// For a directory, `key` is the prefix without its trailing "/" ("" for
  /// the bucket root).
  Object(s3: s3.Config, bucket: String, key: String)
}

pub fn is_s3(text: String) -> Bool {
  string.starts_with(text, "s3://")
}

/// Parse a configured path. `s3` is used for `s3://bucket/key` paths.
pub fn parse(text: String, s3: s3.Config) -> Result(Location, Nil) {
  case text {
    "s3://" <> rest ->
      case string.split_once(rest, "/") {
        Ok(#(bucket, key)) if bucket != "" ->
          Ok(Object(s3, bucket, strip_trailing_slash(key)))
        Error(_) if rest != "" -> Ok(Object(s3, rest, ""))
        _ -> Error(Nil)
      }
    "" -> Error(Nil)
    _ -> Ok(File(text))
  }
}

fn strip_trailing_slash(key: String) -> String {
  case string.ends_with(key, "/") {
    True -> strip_trailing_slash(string.drop_end(key, 1))
    False -> key
  }
}

pub fn to_string(location: Location) -> String {
  case location {
    File(path) -> path
    Object(bucket:, key:, ..) -> "s3://" <> bucket <> "/" <> key
  }
}

/// The directory (or key prefix) containing `location`.
pub fn parent(location: Location) -> Location {
  case location {
    File(path) -> File(parent_path(path))
    Object(key:, ..) ->
      Object(..location, key: case parent_path(key) {
        "." -> ""
        prefix -> prefix
      })
  }
}

fn parent_path(path: String) -> String {
  case list.reverse(string.split(path, "/")) {
    [_, ..rest] if rest != [] -> string.join(list.reverse(rest), "/")
    _ -> "."
  }
}

/// The entry `name` inside the directory `dir`.
pub fn child(dir: Location, name: String) -> Location {
  case dir {
    File(path) -> File(path <> "/" <> name)
    Object(key: "", ..) -> Object(..dir, key: name)
    Object(key:, ..) -> Object(..dir, key: key <> "/" <> name)
  }
}

/// Read the whole file or object. A missing one is `Error("enoent")`.
pub fn read(location: Location) -> Result(BitArray, String) {
  case location {
    File(path) -> sys.read_file(path)
    Object(s3:, bucket:, key:) -> s3.get(s3, bucket, key)
  }
}

/// Replace the file or object atomically: a reader (or a restart after a
/// crash) sees either the previous complete contents or the new ones.
pub fn write(location: Location, data: BitArray) -> Result(Nil, String) {
  case location {
    File(path) -> sys.atomic_write(path, data)
    Object(s3:, bucket:, key:) -> s3.put(s3, bucket, key, data)
  }
}

pub fn delete(location: Location) -> Result(Nil, String) {
  case location {
    File(path) -> sys.delete_file(path)
    Object(s3:, bucket:, key:) -> s3.delete(s3, bucket, key)
  }
}

/// Create the directory if needed (S3 has no directories: a no-op).
pub fn ensure_dir(dir: Location) -> Result(Nil, String) {
  case dir {
    File(path) -> sys.ensure_dir(path)
    Object(..) -> Ok(Nil)
  }
}

/// Names of the entries directly inside `dir`. A missing directory is empty.
pub fn list_dir(dir: Location) -> Result(List(String), String) {
  case dir {
    File(path) ->
      case sys.list_dir(path) {
        Error("enoent") -> Ok([])
        other -> other
      }
    Object(s3:, bucket:, key:) -> {
      let prefix = case key {
        "" -> ""
        _ -> key <> "/"
      }
      s3.list(s3, bucket, prefix)
      |> result.map(
        list.filter_map(_, fn(full) {
          case string.drop_start(full, string.length(prefix)) {
            "" -> Error(Nil)
            name ->
              case string.contains(name, "/") {
                True -> Error(Nil)
                False -> Ok(name)
              }
          }
        }),
      )
    }
  }
}
