import gleam/list
import gleam/option.{Some}
import gleam/set
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
