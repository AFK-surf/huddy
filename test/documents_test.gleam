import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import huddy/blob
import huddy/codec
import huddy/config
import huddy/doc_lock
import huddy/documents
import huddy/model
import huddy/persist
import huddy/state
import huddy/store
import support

const now = 1_791_622_800_000

@external(erlang, "huddy_ffi", "zip_create")
fn zip_create(files: List(#(String, BitArray))) -> Result(BitArray, String)

fn zip(files: List(#(String, String))) -> BitArray {
  let assert Ok(bits) =
    zip_create(list.map(files, fn(f) { #(f.0, bit_array.from_string(f.1)) }))
  bits
}

fn paths(unpacked: documents.Unpacked) -> List(String) {
  list.map(unpacked.files, fn(f) { f.path })
}

// --- unpacking -------------------------------------------------------------------

pub fn markdown_becomes_index_test() {
  let assert Ok(documents.Unpacked(zip:, files: [file])) =
    documents.unpack(documents.Markdown("# Hello\n"), 1000)
  assert file
    == documents.UnpackedFile("index.md", "index.md", <<"# Hello\n":utf8>>)
  // stored as a zip holding it
  let assert Ok(documents.Unpacked(files: [again], ..)) =
    documents.unpack(documents.Zip(zip), 1000)
  assert again == file
}

pub fn zip_with_images_test() {
  let raw =
    zip([
      #("index.md", "# Plan\n![arch](img/arch.png)"),
      #("img/arch.png", "PNG"),
      #("./notes/extra.md", "more"),
      #("__MACOSX/._index.md", "junk"),
      #("img/.DS_Store", "junk"),
    ])
  let assert Ok(unpacked) = documents.unpack(documents.Zip(raw), 10_000)
  assert paths(unpacked) == ["img/arch.png", "index.md", "notes/extra.md"]
  // the zip is kept as uploaded, junk and all
  assert unpacked.zip == raw
  let assert Ok(extra) =
    list.find(unpacked.files, fn(f) { f.path == "notes/extra.md" })
  assert extra.entry == "./notes/extra.md"
}

pub fn zip_of_a_folder_is_accepted_test() {
  let upload =
    documents.Zip(
      zip([#("my-doc/index.md", "# Doc"), #("my-doc/img/a.png", "PNG")]),
    )
  let assert Ok(unpacked) = documents.unpack(upload, 10_000)
  assert paths(unpacked) == ["img/a.png", "index.md"]
  assert list.map(unpacked.files, fn(f) { f.entry })
    == ["my-doc/img/a.png", "my-doc/index.md"]
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
    files: [
      model.DocFile("index.md", 10, "index.md"),
      model.DocFile("img/a.png", 5, "img/a.png"),
    ],
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

pub fn sharing_a_document_publicly_test() {
  let #(s, a, b) = support.two_agents(now)
  let assert Ok(#(s, doc, _)) =
    state.put_document(s, a, new_doc("Spec", None), now)
  assert doc.public == None
  // user 1 (alice) shares it
  let assert Ok(#(s, shared)) = state.share_document(s, doc.id, 1, "n1", now)
  assert shared.public == Some(model.PublicLink(nonce: "n1", by: 1, at: now))
  // sharing again keeps the link
  let assert Ok(#(s, again)) = state.share_document(s, doc.id, 2, "n2", now + 1)
  assert again.public == shared.public
  // a new version, by any agent, stays shared
  let assert Ok(#(s, v2, _)) =
    state.put_document(s, b, new_doc("Spec v2", Some(at(doc.id, 1))), now)
  assert v2.public == shared.public
  // it survives the state file, and its user must exist
  let assert Ok(loaded) = persist.decode_file(persist.encode(s, now), "test")
  assert loaded.documents == s.documents
  assert codec.check_references(s) == Ok(Nil)
  let broken =
    model.State(
      ..s,
      documents: dict.insert(
        s.documents,
        doc.id,
        model.Document(
          ..v2,
          public: Some(model.PublicLink(nonce: "n1", by: 99, at: now)),
        ),
      ),
    )
  let assert Error(message) = codec.check_references(broken)
  assert string.contains(message, "document public link")
  // unsharing drops the link; sharing again makes a new one
  let assert Ok(#(s, unshared)) = state.unshare_document(s, doc.id, 2, now)
  assert unshared.public == None
  let assert Ok(#(_, reshared)) = state.share_document(s, doc.id, 2, "n3", now)
  assert reshared.public == Some(model.PublicLink(nonce: "n3", by: 2, at: now))
  assert state.share_document(s, 42, 1, "n", now) == Error("No document doc42.")
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

pub fn work_whose_caller_gave_up_never_runs_test() {
  let assert Ok(started) = doc_lock.start(process.new_name("test_doc_locks_2"))
  let locks = started.data
  let log = process.new_subject()
  // keep document 1 busy for a while
  process.spawn(fn() {
    doc_lock.run(locks, 1, 5000, fn() { process.sleep(300) })
  })
  process.sleep(20)
  // this caller gives up before its turn comes
  assert doc_lock.run(locks, 1, 50, fn() { process.send(log, "ran") })
    == Error(doc_lock.NotStarted)
  // its turn comes and goes without the work
  process.sleep(1500)
  assert process.receive(log, 0) == Error(Nil)
  assert doc_lock.run(locks, 1, 1000, fn() { "next" }) == Ok("next")
}

pub fn a_failed_write_keeps_the_value_test() {
  let cfg = support.config(support.tmp_dir(), 1)
  let cfg =
    config.Config(
      ..cfg,
      storage: config.Storage(
        ..cfg.storage,
        path: blob.File("/proc/huddy-test/huddy.json"),
      ),
    )
  let assert Ok(started) =
    store.start(
      cfg,
      fn() { Ok(model.empty_state()) },
      process.new_name("test_store"),
    )
  let s = started.data
  // the change is in memory and retried; the caller still learns the value
  assert store.update_or_pending(s, fn(st, e, _) { store.Changed(st, e, [], 7) })
    == Ok(#(7, False))
  assert store.update_or_pending(s, fn(_, _, _) { store.NoChange(8) })
    == Ok(#(8, True))
}
