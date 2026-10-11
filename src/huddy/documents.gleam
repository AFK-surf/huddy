//// Documents: Markdown with images, uploaded by agents and readable by every
//// agent and every human (they are not namespaced by owner or project).
////
//// An upload is a zip archive with `index.md` at its root (or inside a single
//// top-level folder), plus any images and other files `index.md` links to;
//// plain Markdown is accepted as a document with only `index.md`. The zip is
//// checked, then stored as uploaded, one object per version, through
//// `huddy/blob` (local disk or S3) at `storage.documents_dir/<storage_key>.zip`
//// (Markdown is stored as a zip holding it). Files are read out of the zip
//// on demand; recently read zips are cached in memory. The state file holds
//// the metadata (`model.Document`), including each file's name in the zip.
//// A new version gets a fresh storage key; the old version's zip is deleted
//// once the state change is durable.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import huddy/blob.{type Location}
import huddy/ctx.{type Ctx}
import huddy/doc_lock
import huddy/model.{type DocFile, type DocRevision, type Document, DocFile}
import huddy/state
import huddy/store
import huddy/sys
import logging

pub const max_files = 200

const max_path_bytes = 200

pub type Upload {
  /// a zip archive with index.md
  Zip(BitArray)
  /// the text of index.md
  Markdown(String)
}

/// Tell a zip archive from Markdown by its magic number.
pub fn detect(body: BitArray) -> Result(Upload, String) {
  case body {
    <<0x50, 0x4B, 0x03, 0x04, _:bytes>> -> Ok(Zip(body))
    _ ->
      case bit_array.to_string(body) {
        Ok(text) -> Ok(Markdown(text))
        Error(_) ->
          Error("The upload is neither a zip archive nor UTF-8 Markdown.")
      }
  }
}

pub fn max_bytes(ctx: Ctx) -> Int {
  ctx.config.limits.document_max_mb * 1_048_576
}

@external(erlang, "huddy_ffi", "zip_extract")
fn zip_extract(
  zip: BitArray,
  max_files: Int,
  max_bytes: Int,
) -> Result(List(#(String, BitArray)), String)

@external(erlang, "huddy_ffi", "zip_create")
fn zip_create(files: List(#(String, BitArray))) -> Result(BitArray, String)

@external(erlang, "huddy_ffi", "zip_read")
fn zip_read(zip: BitArray, entry: String) -> Result(BitArray, String)

@external(erlang, "huddy_ffi", "zip_cache_init")
pub fn cache_init() -> Nil

@external(erlang, "huddy_ffi", "zip_cache_get")
fn cache_get(storage_key: String) -> Result(BitArray, Nil)

@external(erlang, "huddy_ffi", "zip_cache_put")
fn cache_put(storage_key: String, zip: BitArray, max_bytes: Int) -> Nil

@external(erlang, "huddy_ffi", "zip_cache_delete")
fn cache_delete(storage_key: String) -> Nil

/// The zip cache holds at most this much.
const cache_bytes = 67_108_864

/// A checked upload: the zip to store, and its files.
pub type Unpacked {
  Unpacked(zip: BitArray, files: List(UnpackedFile))
}

pub type UnpackedFile {
  /// `path` is the file's path in the document; `entry` its name in the zip
  UnpackedFile(path: String, entry: String, data: BitArray)
}

/// Unpack and check an upload: safe relative paths, no duplicates, an
/// `index.md` that is UTF-8, within the size and file-count limits. Returns
/// the zip to store (the upload itself, or for Markdown a zip holding it)
/// and the files, sorted by path.
pub fn unpack(upload: Upload, max_bytes: Int) -> Result(Unpacked, String) {
  let too_large =
    "The document is larger than "
    <> int.to_string(max_bytes / 1_048_576)
    <> " MB unzipped."
  use #(zip, entries) <- result.try(case upload {
    Markdown(text) -> {
      let index = [#("index.md", bit_array.from_string(text))]
      zip_create(index)
      |> result.map(fn(zip) { #(zip, index) })
      |> result.replace_error("Could not pack the document.")
    }
    Zip(bits) ->
      zip_extract(bits, max_files, max_bytes)
      |> result.map_error(fn(reason) {
        case reason {
          "too_large" -> too_large
          "too_many_files" ->
            "The zip archive has more than "
            <> int.to_string(max_files)
            <> " files."
          "unsafe_name:" <> name -> unsafe_name(name)
          _ -> "The upload is not a valid zip archive."
        }
      })
      |> result.map(fn(entries) { #(bits, entries) })
  })
  use entries <- result.try(
    entries
    |> list.filter(fn(e) { !is_junk(e.0) })
    |> list.try_map(fn(e) {
      case normalize_path(e.0) {
        Ok(path) -> Ok(UnpackedFile(path:, entry: e.0, data: e.1))
        Error(_) -> Error(unsafe_name(e.0))
      }
    }),
  )
  let entries = strip_common_folder(entries)
  let paths = list.map(entries, fn(e) { e.path })
  use _ <- result.try(
    case list.length(list.unique(paths)) == list.length(paths) {
      True -> Ok(Nil)
      False -> Error("The zip archive has duplicate file names.")
    },
  )
  use _ <- result.try(
    case list.fold(entries, 0, fn(n, e) { n + bit_array.byte_size(e.data) }) {
      n if n > max_bytes -> Error(too_large)
      _ -> Ok(Nil)
    },
  )
  use index <- result.try(
    list.find(entries, fn(e) { e.path == "index.md" })
    |> result.replace_error(
      "The document has no index.md at the root of the zip archive.",
    ),
  )
  use _ <- result.try(case bit_array.to_string(index.data) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("index.md is not valid UTF-8.")
  })
  Ok(Unpacked(
    zip:,
    files: list.sort(entries, fn(a, b) { string.compare(a.path, b.path) }),
  ))
}

fn unsafe_name(name: String) -> String {
  "Unsafe file name in the zip archive: "
  <> string.inspect(name)
  <> ". Use relative paths without \"..\"."
}

/// Archive noise from macOS and Windows.
fn is_junk(name: String) -> Bool {
  let segments = string.split(name, "/")
  list.contains(segments, "__MACOSX")
  || case list.last(segments) {
    Ok(".DS_Store") | Ok("Thumbs.db") -> True
    _ -> False
  }
}

/// A safe relative path: "/"-separated, no "..", no empty or absolute
/// paths, no backslashes or control characters. "./" segments are dropped.
pub fn normalize_path(name: String) -> Result(String, Nil) {
  let segments =
    string.split(name, "/")
    |> list.filter(fn(s) { s != "" && s != "." })
  let ok =
    !string.starts_with(name, "/")
    && !string.contains(name, "\\")
    && segments != []
    && !list.contains(segments, "..")
    && string.byte_size(name) <= max_path_bytes
    && string.to_utf_codepoints(name)
    |> list.all(fn(cp) {
      let n = string.utf_codepoint_to_int(cp)
      n >= 32 && n != 127
    })
  case ok {
    True -> Ok(string.join(segments, "/"))
    False -> Error(Nil)
  }
}

/// `zip -r doc.zip doc/` puts everything under `doc/`: accept that when
/// there is no root index.md but `doc/index.md` exists.
fn strip_common_folder(entries: List(UnpackedFile)) -> List(UnpackedFile) {
  let has = fn(path) { list.any(entries, fn(e) { e.path == path }) }
  let folders =
    entries
    |> list.map(fn(e) {
      case string.split_once(e.path, "/") {
        Ok(#(folder, _)) -> Ok(folder)
        Error(_) -> Error(Nil)
      }
    })
    |> list.unique
  case has("index.md"), folders {
    False, [Ok(folder)] ->
      case has(folder <> "/index.md") {
        True ->
          list.map(entries, fn(e) {
            UnpackedFile(
              ..e,
              path: string.drop_start(e.path, string.length(folder) + 1),
            )
          })
        False -> entries
      }
    _, _ -> entries
  }
}

/// The text of the first `# ` heading, if any.
pub fn heading(markdown: String) -> Option(String) {
  markdown
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case string.trim_end(line) {
      "# " <> rest ->
        case string.trim(rest) {
          "" -> Error(Nil)
          t -> Ok(t)
        }
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// A title on one line, with whitespace collapsed.
pub fn one_line(text: String) -> String {
  text
  |> string.replace("\r", " ")
  |> string.replace("\n", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(w) { w != "" })
  |> string.join(" ")
}

fn location(ctx: Ctx, storage_key: String) -> Location {
  blob.child(ctx.config.storage.documents_dir, storage_key <> ".zip")
}

/// Delete one version's zip in the background.
pub fn discard(ctx: Ctx, storage_key: String) -> Nil {
  cache_delete(storage_key)
  let zip = location(ctx, storage_key)
  process.spawn_unlinked(fn() {
    case blob.delete(zip) {
      Ok(_) -> Nil
      Error(reason) ->
        logging.log(
          logging.Warning,
          "documents: could not delete "
            <> blob.to_string(zip)
            <> ": "
            <> reason,
        )
    }
  })
  Nil
}

/// A stored upload. `durable` is False when the state file could not be
/// written yet: the document is in memory and is saved when the write is
/// retried, so it must not be uploaded again.
pub type Stored {
  Stored(doc: Document, durable: Bool)
}

pub type UploadError {
  /// Nothing was stored; the upload can be fixed and retried.
  NotStored(String)
  /// The outcome is unknown; check the document before retrying.
  Unknown(String)
}

/// How long an operation waits for earlier changes to the same document.
const lock_timeout_ms = 120_000

/// Upload a new document for `agent_id`, or a new version of any document
/// (`replaces`, which must still be at the given revision). A new version is
/// stored on the document's actor (`huddy/doc_lock`), after any other change
/// to it. The title is `title`, else the first `# ` heading of index.md,
/// else (for a new version) the previous title.
pub fn upload(
  ctx: Ctx,
  agent_id: Int,
  upload: Upload,
  title: Option(String),
  replaces: Option(DocRevision),
) -> Result(Stored, UploadError) {
  use unpacked <- result.try(
    unpack(upload, max_bytes(ctx)) |> result.map_error(NotStored),
  )
  case replaces {
    None -> store_version(ctx, agent_id, unpacked, title, None)
    Some(at) ->
      doc_lock.run(ctx.doc_locks, at.id, lock_timeout_ms, fn() {
        // refuse a stale revision before writing any files; put_document
        // checks again when recording the change
        case store.read(ctx.store, fn(s, _) { state.check_revision(s, at) }) {
          Error(reason) -> Error(NotStored(reason))
          Ok(_) -> store_version(ctx, agent_id, unpacked, title, Some(at))
        }
      })
      |> result.map_error(fn(failure) {
        case failure {
          doc_lock.NotStarted -> NotStored(doc_lock.describe(failure))
          _ -> Unknown(doc_lock.describe(failure))
        }
      })
      |> result.flatten
  }
}

fn store_version(
  ctx: Ctx,
  agent_id: Int,
  unpacked: Unpacked,
  title: Option(String),
  replaces: Option(DocRevision),
) -> Result(Stored, UploadError) {
  let limit = ctx.config.limits.title_max_chars
  let index =
    list.find(unpacked.files, fn(f) { f.path == "index.md" })
    |> result.try(fn(f) { bit_array.to_string(f.data) })
    |> result.unwrap("")
  let previous_title =
    option.then(replaces, fn(at) {
      store.read(ctx.store, fn(s, _) { state.get_document(s, at.id) })
      |> option.map(fn(d) { d.title })
    })
  let title =
    title
    |> option.map(one_line)
    |> option.then(fn(t) {
      case t {
        "" -> None
        _ -> Some(t)
      }
    })
    |> option.lazy_or(fn() { option.map(heading(index), one_line) })
    |> option.or(previous_title)
  use title <- result.try(case title {
    None ->
      Error(NotStored(
        "Give the document a `title`, or start index.md with a \"# \" heading.",
      ))
    Some(t) ->
      case string.length(t) > limit {
        True ->
          Error(NotStored(
            "The title is longer than "
            <> int.to_string(limit)
            <> " characters.",
          ))
        False -> Ok(t)
      }
  })
  let key = sys.random_token(12)
  use _ <- result.try(
    blob.write(location(ctx, key), unpacked.zip)
    |> result.map_error(fn(reason) {
      NotStored("Could not store the document: " <> reason)
    }),
  )
  let doc_files =
    list.map(unpacked.files, fn(f) {
      DocFile(path: f.path, size: bit_array.byte_size(f.data), entry: f.entry)
    })
  let stored =
    store.update_or_pending(ctx.store, fn(s, e, now) {
      case
        state.put_document(
          s,
          agent_id,
          state.NewDocument(
            title:,
            files: doc_files,
            storage_key: key,
            replaces:,
          ),
          now,
        )
      {
        Ok(#(s, doc, old_key)) ->
          store.Changed(s, e, [store.Publish], Ok(#(doc, old_key)))
        Error(reason) -> store.NoChange(Error(reason))
      }
    })
  case stored {
    Ok(#(Ok(#(doc, old_key)), True)) -> {
      option.map(old_key, discard(ctx, _))
      Ok(Stored(doc, durable: True))
    }
    // The change is in memory and will be saved when the write is retried.
    // Keep both zips: until then the state file on disk still names the old
    // one.
    Ok(#(Ok(#(doc, _)), False)) -> Ok(Stored(doc, durable: False))
    Ok(#(Error(reason), _)) -> {
      discard(ctx, key)
      Error(NotStored(reason))
    }
    // the store did not answer: the change may or may not have been applied
    Error(reason) -> Error(Unknown(reason))
  }
}

/// Delete a document, if it is still at the given revision, and once that
/// is durable its files. Runs on the document's actor, after any other
/// change to it. `actor` is `state.agent_actor(…)` or `state.user_actor(…)`.
pub fn delete(
  ctx: Ctx,
  at: DocRevision,
  actor: String,
) -> Result(Document, String) {
  doc_lock.run(ctx.doc_locks, at.id, lock_timeout_ms, fn() {
    case
      store.update_or_pending(ctx.store, fn(s, e, now) {
        case state.delete_document(s, at, actor, now) {
          Ok(#(s, doc)) -> store.Changed(s, e, [store.Publish], Ok(doc))
          Error(reason) -> store.NoChange(Error(reason))
        }
      })
    {
      Ok(#(Ok(doc), durable)) -> {
        // until a failed write is retried, the state file on disk still
        // names the zip: keep it then
        case durable {
          True -> discard(ctx, doc.storage_key)
          False -> Nil
        }
        Ok(doc)
      }
      Ok(#(Error(reason), _)) | Error(reason) -> Error(reason)
    }
  })
  |> result.map_error(doc_lock.describe)
  |> result.flatten
}

/// The stored zip of the document's current version.
pub fn zip(ctx: Ctx, doc: Document) -> Result(BitArray, String) {
  case cache_get(doc.storage_key) {
    Ok(zip) -> Ok(zip)
    Error(_) -> {
      use zip <- result.try(blob.read(location(ctx, doc.storage_key)))
      cache_put(doc.storage_key, zip, cache_bytes)
      Ok(zip)
    }
  }
}

/// One file of a document, if the document has it, read out of its zip.
pub fn read_file(
  ctx: Ctx,
  doc: Document,
  path: String,
) -> Result(BitArray, String) {
  case list.find(doc.files, fn(f) { f.path == path }) {
    Error(_) -> Error("enoent")
    Ok(file) -> {
      use zip <- result.try(zip(ctx, doc))
      zip_read(zip, file.entry)
    }
  }
}

pub fn url(ctx: Ctx, doc_id: Int) -> String {
  ctx.config.base_url <> "/docs/" <> model.doc_ref(doc_id)
}

/// "12 KB", "3.4 MB".
pub fn size_label(bytes: Int) -> String {
  case bytes {
    b if b < 1024 -> int.to_string(b) <> " B"
    b if b < 1_048_576 -> int.to_string({ b + 1023 } / 1024) <> " KB"
    b -> {
      let tenths = { b * 10 + 524_288 } / 1_048_576
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> " MB"
    }
  }
}

pub fn files_label(files: List(DocFile)) -> String {
  case list.length(files) {
    1 -> "1 file"
    n -> int.to_string(n) <> " files"
  }
}
