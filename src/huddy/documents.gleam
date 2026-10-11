//// Documents: Markdown with images, uploaded by agents and readable by every
//// agent and every human (they are not namespaced by owner or project).
////
//// An upload is a zip archive with `index.md` at its root (or inside a single
//// top-level folder), plus any images and other files `index.md` links to;
//// plain Markdown is accepted as a document with only `index.md`. Each file
//// is stored on its own through `huddy/blob` (local disk or S3), under
//// `storage.documents_dir/<storage_key>/<path>`, so serving one image is one
//// read. The state file holds the metadata (`model.Document`). A new version
//// gets a fresh storage key; the old version's files are deleted once the
//// state change is durable.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import huddy/blob.{type Location}
import huddy/ctx.{type Ctx}
import huddy/model.{type DocFile, type Document, DocFile}
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

/// Unpack and check an upload: safe relative paths, no duplicates, an
/// `index.md` that is UTF-8, within the size and file-count limits. Returns
/// the files sorted by path.
pub fn unpack(
  upload: Upload,
  max_bytes: Int,
) -> Result(List(#(String, BitArray)), String) {
  let too_large =
    "The document is larger than "
    <> int.to_string(max_bytes / 1_048_576)
    <> " MB unzipped."
  use entries <- result.try(case upload {
    Markdown(text) -> Ok([#("index.md", bit_array.from_string(text))])
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
  })
  use entries <- result.try(
    entries
    |> list.filter(fn(e) { !is_junk(e.0) })
    |> list.try_map(fn(e) {
      case normalize_path(e.0) {
        Ok(path) -> Ok(#(path, e.1))
        Error(_) -> Error(unsafe_name(e.0))
      }
    }),
  )
  let entries = strip_common_folder(entries)
  let paths = list.map(entries, fn(e) { e.0 })
  use _ <- result.try(
    case list.length(list.unique(paths)) == list.length(paths) {
      True -> Ok(Nil)
      False -> Error("The zip archive has duplicate file names.")
    },
  )
  use _ <- result.try(
    case list.fold(entries, 0, fn(n, e) { n + bit_array.byte_size(e.1) }) {
      n if n > max_bytes -> Error(too_large)
      _ -> Ok(Nil)
    },
  )
  use index <- result.try(
    list.key_find(entries, "index.md")
    |> result.replace_error(
      "The document has no index.md at the root of the zip archive.",
    ),
  )
  use _ <- result.try(case bit_array.to_string(index) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("index.md is not valid UTF-8.")
  })
  Ok(list.sort(entries, fn(a, b) { string.compare(a.0, b.0) }))
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
fn strip_common_folder(
  entries: List(#(String, BitArray)),
) -> List(#(String, BitArray)) {
  let folders =
    entries
    |> list.map(fn(e) {
      case string.split_once(e.0, "/") {
        Ok(#(folder, _)) -> Ok(folder)
        Error(_) -> Error(Nil)
      }
    })
    |> list.unique
  case list.key_find(entries, "index.md"), folders {
    Error(_), [Ok(folder)] ->
      case list.key_find(entries, folder <> "/index.md") {
        Ok(_) ->
          list.map(entries, fn(e) {
            #(string.drop_start(e.0, string.length(folder) + 1), e.1)
          })
        Error(_) -> entries
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

fn location(ctx: Ctx, storage_key: String, path: String) -> Location {
  blob.child(blob.child(ctx.config.storage.documents_dir, storage_key), path)
}

/// Write the files under a fresh storage key. On failure, whatever was
/// written is removed.
fn store_files(
  ctx: Ctx,
  files: List(#(String, BitArray)),
) -> Result(String, String) {
  let key = sys.random_token(12)
  case
    list.try_each(files, fn(f) { blob.write(location(ctx, key, f.0), f.1) })
  {
    Ok(_) -> Ok(key)
    Error(reason) -> {
      discard(ctx, key)
      Error("Could not store the document: " <> reason)
    }
  }
}

/// Delete one version's files in the background.
pub fn discard(ctx: Ctx, storage_key: String) -> Nil {
  let dir = blob.child(ctx.config.storage.documents_dir, storage_key)
  process.spawn_unlinked(fn() {
    case blob.delete_tree(dir) {
      Ok(_) -> Nil
      Error(reason) ->
        logging.log(
          logging.Warning,
          "documents: could not delete "
            <> blob.to_string(dir)
            <> ": "
            <> reason,
        )
    }
  })
  Nil
}

/// Upload a new document for `agent_id`, or a new version of one of its
/// documents (`replaces`). The title is `title`, else the first `# ` heading
/// of index.md, else (for a new version) the previous title.
pub fn upload(
  ctx: Ctx,
  agent_id: Int,
  upload: Upload,
  title: Option(String),
  replaces: Option(Int),
) -> Result(Document, String) {
  let limit = ctx.config.limits.title_max_chars
  use files <- result.try(unpack(upload, max_bytes(ctx)))
  let index =
    list.key_find(files, "index.md")
    |> result.try(bit_array.to_string)
    |> result.unwrap("")
  let previous_title =
    option.then(replaces, fn(id) {
      store.read(ctx.store, fn(s, _) { state.get_document(s, id) })
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
      Error(
        "Give the document a `title`, or start index.md with a \"# \" heading.",
      )
    Some(t) ->
      case string.length(t) > limit {
        True ->
          Error(
            "The title is longer than "
            <> int.to_string(limit)
            <> " characters.",
          )
        False -> Ok(t)
      }
  })
  use key <- result.try(store_files(ctx, files))
  let doc_files =
    list.map(files, fn(f) { DocFile(path: f.0, size: bit_array.byte_size(f.1)) })
  let stored =
    store.update(ctx.store, fn(s, e, now) {
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
    |> result.flatten
  case stored {
    Ok(#(doc, old_key)) -> {
      option.map(old_key, discard(ctx, _))
      Ok(doc)
    }
    Error(reason) -> {
      // a storage error keeps the change in memory (it is retried), so the
      // files must stay; anything else never referenced them
      case string.starts_with(reason, "storage") {
        True -> Nil
        False -> discard(ctx, key)
      }
      Error(reason)
    }
  }
}

/// One file of a document, if the document has it.
pub fn read_file(
  ctx: Ctx,
  doc: Document,
  path: String,
) -> Result(BitArray, String) {
  case list.any(doc.files, fn(f) { f.path == path }) {
    False -> Error("enoent")
    True -> blob.read(location(ctx, doc.storage_key, path))
  }
}

/// The document as a zip archive, rebuilt from its files.
pub fn zip(ctx: Ctx, doc: Document) -> Result(BitArray, String) {
  use files <- result.try(
    list.try_map(doc.files, fn(f) {
      read_file(ctx, doc, f.path) |> result.map(fn(bits) { #(f.path, bits) })
    }),
  )
  zip_create(files)
}

/// Is this file text an agent can read as-is?
pub fn is_text(path: String) -> Bool {
  case blob.content_type(path) {
    "text/" <> _ | "application/json" | "image/svg+xml" -> True
    _ -> False
  }
}

/// Raster images an MCP client can show as an image content block.
pub fn is_image(path: String) -> Bool {
  case blob.content_type(path) {
    "image/png" | "image/jpeg" | "image/gif" | "image/webp" -> True
    _ -> False
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
