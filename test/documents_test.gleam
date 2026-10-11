import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import huddy/blob
import huddy/codec
import huddy/doc_lock
import huddy/documents
import huddy/model
import huddy/persist
import huddy/state
import support

const now = 1_791_622_800_000

@external(erlang, "huddy_ffi", "zip_create")
fn zip_create(files: List(#(String, BitArray))) -> Result(BitArray, String)

fn zip(files: List(#(String, String))) -> BitArray {
  let assert Ok(bits) =
    zip_create(list.map(files, fn(f) { #(f.0, bit_array.from_string(f.1)) }))
  bits
}

fn paths(files: List(#(String, BitArray))) -> List(String) {
  list.map(files, fn(f) { f.0 })
}

// --- unpacking -------------------------------------------------------------------

pub fn markdown_becomes_index_test() {
  let assert Ok([#("index.md", bits)]) =
    documents.unpack(documents.Markdown("# Hello\n"), 1000)
  assert bits == <<"# Hello\n":utf8>>
}

pub fn zip_with_images_test() {
  let upload =
    documents.Zip(
      zip([
        #("index.md", "# Plan\n![arch](img/arch.png)"),
        #("img/arch.png", "PNG"),
        #("./notes/extra.md", "more"),
        #("__MACOSX/._index.md", "junk"),
        #("img/.DS_Store", "junk"),
      ]),
    )
  let assert Ok(files) = documents.unpack(upload, 10_000)
  assert paths(files) == ["img/arch.png", "index.md", "notes/extra.md"]
}

pub fn zip_of_a_folder_is_accepted_test() {
  let upload =
    documents.Zip(
      zip([#("my-doc/index.md", "# Doc"), #("my-doc/img/a.png", "PNG")]),
    )
  let assert Ok(files) = documents.unpack(upload, 10_000)
  assert paths(files) == ["img/a.png", "index.md"]
}

pub fn zip_without_index_is_rejected_test() {
  let assert Error(message) =
    documents.unpack(documents.Zip(zip([#("README.md", "# Doc")])), 10_000)
  assert string.contains(message, "no index.md")
}

pub fn unsafe_paths_are_rejected_test() {
  let assert Error(message) =
    documents.unpack(
      documents.Zip(zip([#("index.md", "x"), #("../escape.png", "x")])),
      10_000,
    )
  assert string.contains(message, "Unsafe file name")
  assert documents.normalize_path("/etc/passwd") == Error(Nil)
  assert documents.normalize_path("a\\b.png") == Error(Nil)
  assert documents.normalize_path("img/../../x") == Error(Nil)
  assert documents.normalize_path("./img//a.png") == Ok("img/a.png")
}

pub fn size_limits_test() {
  let big = string.repeat("x", 2000)
  let assert Error(message) =
    documents.unpack(documents.Zip(zip([#("index.md", big)])), 1000)
  assert string.contains(message, "larger than")
  let assert Error(_) = documents.unpack(documents.Markdown(big), 1000)
  let many =
    int.range(1, documents.max_files + 2, [], fn(acc, n) { [n, ..acc] })
    |> list.map(fn(n) { #("f" <> string.inspect(n) <> ".txt", "x") })
  let assert Error(message) =
    documents.unpack(documents.Zip(zip([#("index.md", "x"), ..many])), 100_000)
  assert string.contains(message, "more than")
}

pub fn garbage_is_not_a_zip_test() {
  let assert Error(message) =
    documents.unpack(documents.Zip(<<"PK", 3, 4, "nonsense":utf8>>), 1000)
  assert string.contains(message, "not a valid zip")
  assert documents.detect(<<0xff, 0xfe>>) |> option.from_result == None
  let assert Ok(documents.Markdown("# Hi")) = documents.detect(<<"# Hi":utf8>>)
}

pub fn heading_and_labels_test() {
  assert documents.heading("intro\n#  Design notes \n## Sub")
    == Some("Design notes")
  assert documents.heading("no heading") == None
  assert documents.size_label(512) == "512 B"
  assert documents.size_label(2048) == "2 KB"
  assert documents.size_label(3_500_000) == "3.3 MB"
  assert blob.content_type("img/A.PNG") == "image/png"
  assert blob.content_type("Makefile") == "application/octet-stream"
}

// --- state -----------------------------------------------------------------------

fn at(id: Int, revision: Int) -> model.DocRevision {
  model.DocRevision(id:, revision:)
}

fn new_doc(title: String, replaces) -> state.NewDocument {
  state.NewDocument(
    title:,
    files: [model.DocFile("index.md", 10), model.DocFile("img/a.png", 5)],
    storage_key: "key-" <> title,
    replaces:,
  )
}

pub fn any_agent_can_version_a_document_test() {
  let #(s, a, b) = support.two_agents(now)
  let assert Ok(#(s, doc, None)) =
    state.put_document(s, a, new_doc("v1", None), now)
  assert doc.version == 1
  assert doc.size == 15
  assert model.doc_ref(doc.id) == "doc1"
  let assert Ok(#(s, doc2, Some("key-v1"))) =
    state.put_document(s, a, new_doc("v2", Some(at(doc.id, 1))), now + 1)
  assert doc2.id == doc.id
  assert doc2.version == 2
  assert doc2.created_at == now
  // documents are shared: another agent can replace it too
  let assert Ok(#(s, doc3, Some("key-v2"))) =
    state.put_document(s, b, new_doc("theirs", Some(at(doc.id, 2))), now + 2)
  assert doc3.version == 3
  assert doc3.agent == a
  assert doc3.updated_by == b
  assert state.doc_byline(s, doc3)
    == "alice/codex/huddy (revision 3 by bob/claude-code/api)"
  // a change based on an older revision is refused
  let assert Error(message) =
    state.put_document(s, a, new_doc("stale", Some(at(doc.id, 2))), now)
  assert string.contains(message, "doc1 is at revision 3, not 2")
  let assert Error(_) = state.delete_document(s, at(doc.id, 1), "agent:1", now)
  let assert Error(_) =
    state.put_document(s, a, new_doc("x", Some(at(99, 1))), now)
  assert list.map(state.documents(s), fn(d) { d.title }) == ["theirs"]
}

pub fn items_link_documents_test() {
  let #(s, a, b) = support.two_agents(now)
  let assert Ok(#(s, doc, _)) =
    state.put_document(s, a, new_doc("Spec", None), now)
  // any agent can link any document
  let #(s, t) =
    state.create_item(
      s,
      b,
      state.NewItem(..support.task("Build it"), docs: [doc.id, doc.id]),
      now,
    )
  assert t.docs == [doc.id]
  assert state.check_docs(s, [doc.id]) == Ok(Nil)
  let assert Error(message) = state.check_docs(s, [doc.id, 42])
  assert string.contains(message, "doc42")
  let assert Error(_) =
    state.edit_item(
      s,
      b,
      t.id,
      state.Edit(None, None, None, None, None, Some([42])),
      now,
    )
  // changing the links is a new version of the item
  let assert Ok(#(s, out)) =
    state.edit_item(
      s,
      b,
      t.id,
      state.Edit(None, None, None, None, None, Some([])),
      now,
    )
  assert out.content_changed
  assert out.item.docs == []
  assert out.item.version == 2
  assert state.items_with_doc(s, doc.id) == []
}

pub fn deleting_a_document_unlinks_it_test() {
  let #(s, a, _) = support.two_agents(now)
  let assert Ok(#(s, doc, _)) =
    state.put_document(s, a, new_doc("Old", None), now)
  let #(s, t) =
    state.create_item(
      s,
      a,
      state.NewItem(..support.task("Uses it"), docs: [doc.id]),
      now,
    )
  assert list.map(state.items_with_doc(s, doc.id), fn(i) { i.id }) == [t.id]
  let assert Ok(#(s, deleted)) =
    state.delete_document(s, at(doc.id, 1), state.agent_actor(a), now)
  assert deleted.storage_key == "key-Old"
  assert state.get_document(s, doc.id) == None
  let assert Some(item) = state.get_item(s, t.id)
  assert item.docs == []
  assert codec.check_references(s) == Ok(Nil)
}

pub fn documents_round_trip_through_the_state_file_test() {
  let #(s, a, _) = support.two_agents(now)
  let assert Ok(#(s, doc, _)) =
    state.put_document(s, a, new_doc("Spec", None), now)
  let #(s, _) =
    state.create_item(
      s,
      a,
      state.NewItem(..support.goal("Ship it"), docs: [doc.id]),
      now,
    )
  let assert Ok(loaded) = persist.decode_file(persist.encode(s, now), "test")
  assert loaded.documents == s.documents
  assert loaded.items == s.items
  assert loaded.next_id == s.next_id
  // a dangling link fails the integrity check
  let broken = model.State(..s, documents: dict.new())
  let assert Error(message) = codec.check_references(broken)
  assert string.contains(message, "item document")
}

pub fn files_written_before_documents_existed_still_load_test() {
  let #(s, _, _) = support.two_agents(now)
  let text =
    persist.encode(s, now)
    |> bit_array.to_string
    |> option.from_result
    |> option.unwrap("")
    |> string.replace(",\"documents\":[]", "")
    |> string.replace(",\"document\":1", "")
  assert !string.contains(text, "document")
  let assert Ok(loaded) =
    persist.decode_file(bit_array.from_string(text), "old")
  assert dict.is_empty(loaded.documents)
  assert loaded.next_id.document == 1
}

// --- storage ---------------------------------------------------------------------

pub fn local_trees_test() {
  let dir = blob.File(support.tmp_dir() <> "/documents/k1")
  assert blob.list_tree(dir) == Ok([])
  let assert Ok(_) = blob.write(blob.child(dir, "index.md"), <<"# x":utf8>>)
  let assert Ok(_) = blob.write(blob.child(dir, "img/deep/a.png"), <<1, 2>>)
  assert blob.list_tree(dir) == Ok(["img/deep/a.png", "index.md"])
  assert blob.read(blob.child(dir, "img/deep/a.png")) == Ok(<<1, 2>>)
  let assert Ok(_) = blob.delete_tree(dir)
  assert blob.list_tree(dir) == Ok([])
  assert blob.delete_tree(dir) == Ok(Nil)
}

// --- one actor per document -----------------------------------------------------

pub fn changes_to_a_document_are_serialized_test() {
  let assert Ok(started) = doc_lock.start(process.new_name("test_doc_locks"))
  let locks = started.data
  let log = process.new_subject()
  let done = process.new_subject()
  let job = fn(doc: Int, n: Int) {
    process.spawn(fn() {
      let result =
        doc_lock.run(locks, doc, 5000, fn() {
          process.send(log, #(doc, "start", n))
          process.sleep(20)
          process.send(log, #(doc, "end", n))
          n
        })
      process.send(done, result)
    })
  }
  list.each([1, 2, 3, 4, 5], job(7, _))
  list.each([1, 2, 3, 4, 5], fn(_) {
    let assert Ok(Ok(_)) = process.receive(done, 5000)
  })
  let events =
    list.map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], fn(_) {
      let assert Ok(e) = process.receive(log, 1000)
      e
    })
  // never two at once: every start is followed by its own end
  assert list.sized_chunk(events, 2)
    |> list.all(fn(pair) {
      case pair {
        [#(_, "start", a), #(_, "end", b)] -> a == b
        _ -> False
      }
    })
  // different documents do not wait for each other
  job(8, 1)
  job(9, 2)
  let assert Ok(#(_, "start", _)) = process.receive(log, 1000)
  let assert Ok(#(_, "start", _)) = process.receive(log, 1000)
  // a crash is an error for its caller, not for the next operation
  let assert Error(_) = doc_lock.run(locks, 7, 1000, fn() { panic as "boom" })
  assert doc_lock.run(locks, 7, 1000, fn() { 42 }) == Ok(42)
}
