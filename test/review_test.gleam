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
  assert !list.contains(names, "kind_fit")
  assert list.contains(names, "readable")
  assert list.contains(names, "importance")
  assert !list.contains(names, "injection")
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
      #("readable", jev.NoulAnswer(0.2)),
      #("importance", jev.ScoreAnswer(2.5, 0.8, dict.new())),
      #("same_as", choice(model.item_ref(theirs.id), 0.8)),
      #("stale_" <> model.item_ref(own.id), jev.NoulAnswer(0.8)),
    ])
  let #(importance, findings) =
    review.interpret_write(req.context, answers, config.default_thresholds(), 7)
  assert importance == Some(2.5)
  let kinds = list.map(findings, fn(f) { f.kind })
  assert list.contains(kinds, model.Unclear)
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
      #("readable", jev.NoulAnswer(0.5)),
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

pub fn task_review_files_the_task_under_a_goal_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, g1) = state.create_item(s, a, support.goal("Ship OAuth login"), now)
  let #(s, g2) = state.create_item(s, a, support.goal("Speed up CI"), now)
  let #(s, t) =
    state.create_item(s, a, support.task("Cache the Gleam build"), now)
  let req = review.write_request(s, t, now)
  let assert Ok(jev.Choice(_, criteria)) = list.key_find(req.questions, "goal")
  assert list.map(criteria, fn(c) { c.0 }) |> list.sort(string.compare)
    == [model.item_ref(g1.id), model.item_ref(g2.id), "none"]
    |> list.sort(string.compare)
  let filing = fn(answer) {
    review.interpret_filing(
      req.context,
      dict.from_list([#("goal", answer)]),
      config.default_thresholds(),
    )
  }
  assert filing(choice(model.item_ref(g2.id), 0.8))
    == review.Filing(goal: Some(Some(g2.id)), tasks: [])
  assert filing(choice("none", 0.9)) == review.Filing(Some(None), [])
  // not confident: leave it where it is
  assert filing(choice(model.item_ref(g1.id), 0.3)) == review.Filing(None, [])
}

pub fn goal_review_adopts_unfiled_tasks_test() {
  let #(s, a, b) = support.two_agents(now)
  // posted before any goal: unfiled
  let #(s, loose) =
    state.create_item(s, a, support.task("Write the setup guide"), now)
  let #(s, old_goal) = state.create_item(s, a, support.goal("Docs"), now)
  // filed under the agent's only goal
  let #(s, filed) =
    state.create_item(s, a, support.task("Proofread the guide"), now)
  assert filed.goal == Some(old_goal.id)
  let #(s, _) = state.create_item(s, b, support.task("Someone else's"), now)
  let #(s, g) =
    state.create_item(s, a, support.goal("Onboard new teammates"), now)
  let req = review.write_request(s, g, now)
  let serves =
    list.filter(req.questions, fn(q) { string.starts_with(q.0, "serves_") })
  assert list.map(serves, fn(q) { q.0 })
    == ["serves_" <> model.item_ref(loose.id)]
  assert !list.any(req.questions, fn(q) { q.0 == "goal" })
  let filing =
    review.interpret_filing(
      req.context,
      dict.from_list([
        #("serves_" <> model.item_ref(loose.id), jev.NoulAnswer(0.8)),
      ]),
      config.default_thresholds(),
    )
  assert filing == review.Filing(None, [loose.id])
  let filing =
    review.interpret_filing(
      req.context,
      dict.from_list([
        #("serves_" <> model.item_ref(loose.id), jev.NoulAnswer(0.2)),
      ]),
      config.default_thresholds(),
    )
  assert filing == review.Filing(None, [])
}
