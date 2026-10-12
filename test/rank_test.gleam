import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import huddy/config
import huddy/model
import huddy/rank
import huddy/state
import support

const now = 1_791_622_800_000

fn display(slots: Int, cap: Int) -> config.Display {
  config.Display(
    ..config.default_display(),
    slots_tasks: slots,
    slots_decisions: slots,
    cap_tasks: cap,
    cap_decisions: cap,
  )
}

fn compute(
  s: model.State,
  d: config.Display,
  previous: rank.Visible,
) -> #(rank.View, rank.Visible) {
  rank.compute(s, d, 0.7, rank.no_filters(), previous, now)
}

fn titles(views: List(rank.ItemView)) -> List(String) {
  list.map(views, fn(v) { v.item.title })
}

pub fn blocking_decisions_are_always_shown_test() {
  let #(s, a, _) = support.two_agents(now)
  let s =
    list.fold(["b1", "b2", "b3"], s, fn(s, t) {
      state.create_item(s, a, support.decision(t, True), now).0
    })
  let #(view, _) = compute(s, display(1, 1), rank.no_visible())
  assert list.length(view.blocking) == 3
  assert view.decisions == []
}

pub fn per_agent_cap_spreads_the_board_test() {
  let #(s, a, b) = support.two_agents(now)
  let s =
    list.fold(["a1", "a2", "a3", "a4"], s, fn(s, t) {
      state.create_item(s, a, support.task(t), now).0
    })
  let #(s, _) = state.create_item(s, b, support.task("b1"), now - 3_600_000)
  let #(view, _) = compute(s, display(3, 2), rank.no_visible())
  // the cap leaves room for bob's older task
  assert list.contains(titles(view.tasks), "b1")
  assert list.length(view.tasks) == 3
  assert view.tasks_more == 2
}

pub fn leftover_slots_ignore_the_cap_test() {
  let #(s, a, _) = support.two_agents(now)
  let s =
    list.fold(["a1", "a2", "a3"], s, fn(s, t) {
      state.create_item(s, a, support.task(t), now).0
    })
  let #(view, _) = compute(s, display(5, 1), rank.no_visible())
  assert list.length(view.tasks) == 3
}

pub fn hysteresis_keeps_visible_items_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, old) = state.create_item(s, a, support.task("old"), now - 600_000)
  let #(s, _) = state.create_item(s, b, support.task("new"), now)
  // without history the fresher task wins the single slot
  let #(view, _) = compute(s, display(1, 1), rank.no_visible())
  assert titles(view.tasks) == ["new"]
  // a slightly fresher newcomer does not displace a visible item
  let previous = rank.Visible(set.new(), set.from_list([old.id]), set.new())
  let #(view, _) = compute(s, display(1, 1), previous)
  assert titles(view.tasks) == ["old"]
}

pub fn hidden_and_stale_items_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, hidden) = state.create_item(s, a, support.task("hidden"), now)
  let #(s, _) = state.create_item(s, a, support.task("visible"), now)
  let assert Ok(s) = state.hide(s, hidden.id, 2, "", now)
  let #(view, _) = compute(s, display(10, 10), rank.no_visible())
  assert titles(view.tasks) == ["visible"]
  assert titles(view.hidden) == ["hidden"]
}

pub fn overlapping_goals_merge_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, g1) = state.create_item(s, a, support.goal("Ship OAuth"), now)
  let #(s, g2) = state.create_item(s, b, support.goal("Ship OAuth login"), now)
  let overlap =
    state.NewFinding(
      agent: b,
      item: Some(g2.id),
      item_version: Some(1),
      related_item: Some(g1.id),
      kind: model.Overlap,
      confidence: Some(0.9),
      message: "",
      judgment: option.None,
    )
  let #(s, _) = state.add_finding(s, overlap, now, 0)
  let #(view, _) = compute(s, display(10, 10), rank.no_visible())
  let assert [group] = view.goals
  assert list.length(group.others) == 1
}

pub fn unseen_count_counts_own_decisions_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, d) = state.create_item(s, a, support.decision("mine?", True), now)
  let #(s, _) = state.create_item(s, b, support.decision("theirs?", True), now)
  assert rank.unseen_decisions_for(s, 1) == 1
  let assert Ok(s) = state.mark_seen(s, d.id, 2, now)
  assert rank.unseen_decisions_for(s, 1) == 0
}

pub fn hide_away_drops_away_agents_but_keeps_their_blockers_test() {
  let #(s, a, b) = support.two_agents(now)
  let then = now - state.hours(3)
  let #(s, _) = state.create_item(s, a, support.goal("Away goal"), then)
  let #(s, _) = state.create_item(s, a, support.task("Away task"), then)
  let #(s, _) =
    state.create_item(s, a, support.decision("Away question", False), then)
  let #(s, _) =
    state.create_item(s, a, support.decision("Away blocker", True), then)
  let #(s, _) = state.create_item(s, b, support.task("Active task"), now)
  let view = fn(hide_away) {
    let filters = rank.Filters(..rank.no_filters(), hide_away:)
    rank.compute(s, display(5, 5), 0.7, filters, rank.no_visible(), now).0
  }
  let agent_ids = fn(v: rank.View) { list.map(v.agents, fn(a) { a.agent.id }) }

  let all = view(False)
  assert agent_ids(all) |> list.sort(int.compare) == [a, b]
  assert titles(all.tasks) |> list.sort(string.compare)
    == ["Active task", "Away task"]
  assert titles(all.decisions) == ["Away question"]
  assert list.length(all.goals) == 1

  let active = view(True)
  assert agent_ids(active) == [b]
  assert titles(active.tasks) == ["Active task"]
  assert active.decisions == []
  assert active.goals == []
  assert titles(active.blocking) == ["Away blocker"]
}

pub fn answered_blockers_sort_after_unanswered_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, d1) =
    state.create_item(s, a, support.decision("oldest", True), now - 3000)
  let #(s, d2) =
    state.create_item(s, a, support.decision("seen", True), now - 2000)
  let #(s, _) = state.create_item(s, a, support.decision("new", True), now)
  let assert Ok(s) = state.mark_seen(s, d2.id, 2, now)
  let assert Ok(#(s, _)) =
    state.add_comment(
      s,
      d1.id,
      model.HumanAuthor(2),
      "do it",
      None,
      state.CommentLimits(1000, 100),
      now,
    )
  let #(view, _) = compute(s, display(3, 3), rank.no_visible())
  assert titles(view.blocking) == ["new", "seen", "oldest"]
  let assert [_, _, answered] = view.blocking
  assert answered.answered == Some(#("bob", now))
  let assert [c] = answered.comments
  assert c.author == "bob"
  assert !c.by_agent
}

pub fn tasks_are_listed_under_their_goals_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, _) = state.create_item(s, a, support.task("Before the goal"), now)
  let #(s, g) = state.create_item(s, a, support.goal("Ship OAuth"), now)
  let #(s, _) = state.create_item(s, a, support.task("Under the goal"), now)
  let #(s, _) = state.create_item(s, b, support.task("Bob's task"), now)
  let #(view, _) = compute(s, display(10, 10), rank.no_visible())
  let assert [group] = view.goals
  assert group.primary.item.id == g.id
  assert titles(group.tasks) == ["Under the goal"]
  assert titles(view.other_tasks) |> list.sort(string.compare)
    == ["Before the goal", "Bob's task"]
  assert list.length(view.tasks) == 3
  // a task whose goal is closed goes back with the others
  let assert Ok(#(s, _)) =
    state.edit_item(
      s,
      a,
      g.id,
      state.Edit(None, None, None, None, Some(model.Achieved), None),
      now,
    )
  let #(view, _) = compute(s, display(10, 10), rank.no_visible())
  assert view.goals == []
  assert list.length(view.other_tasks) == 3
}
