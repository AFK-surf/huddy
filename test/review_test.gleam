import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import huddy/config
import huddy/jev
import huddy/model
import huddy/review
import huddy/state
import support

const now = 1_791_622_800_000

fn choice(c: String, confidence: Float) -> jev.Answer {
  jev.ChoiceAnswer(c, confidence, dict.from_list([#(c, confidence)]))
}

pub fn write_request_shape_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, _) =
    state.create_item(s, b, support.task("Deflake auth test suite"), now)
  let #(s, own) = state.create_item(s, a, support.task("Write rotation"), now)
  let #(s, item) =
    state.create_item(s, a, support.task("Deflake OAuth refresh test"), now)
  let req = review.write_request(s, item, now)
  let names = list.map(req.questions, fn(q) { q.0 })
  assert list.contains(names, "kind_fit")
  assert list.contains(names, "readable")
  assert list.contains(names, "importance")
  assert list.contains(names, "injection")
  assert list.contains(names, "stale_" <> model.item_ref(own.id))
  assert !list.contains(names, "answerable")
  let assert Ok(jev.Choice(_, criteria)) =
    list.key_find(req.questions, "same_as")
  assert list.key_find(criteria, "none") |> option.from_result |> option.is_some
}

pub fn decisions_get_an_answerable_question_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, d) =
    state.create_item(s, a, support.decision("Which DB?", True), now)
  let req = review.write_request(s, d, now)
  assert list.any(req.questions, fn(q) { q.0 == "answerable" })
}

pub fn interpretation_produces_findings_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, theirs) =
    state.create_item(s, b, support.task("Deflake auth test suite"), now)
  let #(s, own) = state.create_item(s, a, support.task("Write rotation"), now)
  let #(s, item) =
    state.create_item(s, a, support.task("Deflake OAuth refresh test"), now)
  let req = review.write_request(s, item, now)
  let answers =
    dict.from_list([
      #("kind_fit", choice("decision", 0.9)),
      #("readable", jev.NoulAnswer(0.2)),
      #("importance", jev.ScoreAnswer(2.5, 0.8, dict.new())),
      #("injection", jev.NoulAnswer(0.9)),
      #("same_as", choice(model.item_ref(theirs.id), 0.8)),
      #(
        "stale_" <> model.item_ref(own.id),
        jev.ChoiceAnswer(
          "finished",
          0.6,
          dict.from_list([
            #("finished", 0.6),
            #("superseded", 0.2),
            #("current", 0.2),
          ]),
        ),
      ),
    ])
  let #(importance, findings) =
    review.interpret_write(req.context, answers, config.default_thresholds(), 7)
  assert importance == Some(2.5)
  let kinds = list.map(findings, fn(f) { f.kind })
  assert list.contains(kinds, model.WrongKind)
  assert list.contains(kinds, model.Unclear)
  assert list.contains(kinds, model.Injection)
  assert list.contains(kinds, model.Stale)
  // overlap goes to both agents
  let overlaps = list.filter(findings, fn(f) { f.kind == model.Overlap })
  assert list.map(overlaps, fn(f) { f.agent }) |> list.sort(int.compare)
    == [a, b] |> list.sort(int.compare)
  let assert Ok(stale) = list.find(findings, fn(f) { f.kind == model.Stale })
  assert stale.item == Some(own.id)
  assert list.all(findings, fn(f) { f.judgment == Some(7) })
}

pub fn below_thresholds_nothing_is_flagged_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, item) = state.create_item(s, a, support.task("Write the docs"), now)
  let req = review.write_request(s, item, now)
  let answers =
    dict.from_list([
      #("kind_fit", choice("decision", 0.6)),
      #("readable", jev.NoulAnswer(0.5)),
      #("injection", jev.NoulAnswer(0.3)),
    ])
  let #(importance, findings) =
    review.interpret_write(req.context, answers, config.default_thresholds(), 1)
  assert importance == None
  assert findings == []
}

pub fn own_duplicate_is_a_duplicate_finding_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, first) =
    state.create_item(s, a, support.task("Deflake the auth tests"), now)
  let #(s, item) =
    state.create_item(s, a, support.task("Deflake auth tests"), now)
  let req = review.write_request(s, item, now)
  let answers =
    dict.from_list([#("same_as", choice(model.item_ref(first.id), 0.9))])
  let #(_, findings) =
    review.interpret_write(req.context, answers, config.default_thresholds(), 1)
  let assert [f] = findings
  assert f.kind == model.Duplicate
  assert string.contains(
    f.message,
    "Consider updating " <> model.item_ref(first.id),
  )
}

pub fn too_many_open_test() {
  let #(s, a, _) = support.two_agents(now)
  let s =
    list.fold(["1", "2", "3"], s, fn(s, t) {
      state.create_item(s, a, support.task(t), now).0
    })
  assert review.too_many_open(s, a, 3, 3) == None
  let assert Some(f) = review.too_many_open(s, a, 2, 3)
  assert string.contains(f.message, "3 open tasks (guideline: 2)")
}

pub fn untouched_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, _) =
    state.create_item(s, a, support.task("old"), now - state.days(4))
  let #(s, _) = state.create_item(s, a, support.task("fresh"), now)
  let found = review.untouched(s, 3, now)
  assert list.length(found) == 1
}
