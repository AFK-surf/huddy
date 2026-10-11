//// Huddy's one storage abstraction. The state file, its backups and the
//// document files all go through it, so every operation below works the same
//// on a local file or directory and on an object or key prefix in S3 (or an
//// S3-compatible store). In the configuration, an `s3://bucket/key` path
//// selects S3; anything else is a local path.

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
/// crash) sees either the previous complete contents or the new ones. A
/// missing parent directory is created. S3 objects get a content type from
/// the name's extension.
pub fn write(location: Location, data: BitArray) -> Result(Nil, String) {
  case location {
    File(path) -> {
      use _ <- result.try(sys.ensure_dir(parent_path(path)))
      sys.atomic_write(path, data)
    }
    Object(s3:, bucket:, key:) ->
      s3.put(s3, bucket, key, data, content_type(key))
  }
}

/// Remove what an interrupted `write` may have left behind: the `.tmp` file
/// next to a local file. S3 writes are single requests and leave nothing.
pub fn discard_partial(location: Location) -> Result(Nil, String) {
  case location {
    File(path) -> sys.delete_file(path <> ".tmp")
    Object(..) -> Ok(Nil)
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

/// Delete `dir` and everything below it. A missing directory is fine.
pub fn delete_tree(dir: Location) -> Result(Nil, String) {
  case dir {
    File(path) -> sys.delete_tree(path)
    Object(..) -> {
      use paths <- result.try(list_tree(dir))
      list.try_each(paths, fn(p) { delete(child(dir, p)) })
    }
  }
}

/// Paths (relative, "/"-separated) of all files below `dir`, at any depth,
/// sorted. A missing directory is empty.
pub fn list_tree(dir: Location) -> Result(List(String), String) {
  case dir {
    File(path) -> sys.list_tree(path)
    Object(s3:, bucket:, key:) -> {
      let prefix = case key {
        "" -> ""
        _ -> key <> "/"
      }
      s3.list(s3, bucket, prefix)
      |> result.map(fn(keys) {
        keys
        |> list.map(string.drop_start(_, string.length(prefix)))
        |> list.filter(fn(p) { p != "" && !string.ends_with(p, "/") })
        |> list.sort(string.compare)
      })
    }
  }
}

/// The media type for a file name, by extension. Unknown types are
/// `application/octet-stream`.
pub fn content_type(name: String) -> String {
  let ext = case list.last(string.split(string.lowercase(name), ".")) {
    Ok(ext) if ext != name -> ext
    _ -> ""
  }
  case ext {
    "json" -> "application/json"
    "md" | "markdown" -> "text/markdown; charset=utf-8"
    "txt" | "log" -> "text/plain; charset=utf-8"
    "csv" -> "text/csv; charset=utf-8"
    "png" -> "image/png"
    "jpg" | "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "svg" -> "image/svg+xml"
    "avif" -> "image/avif"
    "pdf" -> "application/pdf"
    "zip" -> "application/zip"
    _ -> "application/octet-stream"
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
