//// Deterministic ranking and selection of what the display shows.
//// Pure: no decision-model calls, only stored review results and time.

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import huddy/config
import huddy/model.{type Agent, type Item, type State}
import huddy/state

pub type Filters {
  Filters(
    owner: Option(String),
    project: Option(String),
    name: Option(String),
    expand: Option(String),
    /// leave out away agents and their items (but not their blockers)
    hide_away: Bool,
  )
}

/// The default board: everyone, minus away agents.
pub fn no_filters() -> Filters {
  Filters(None, None, None, None, True)
}

pub fn is_default(filters: Filters) -> Bool {
  filters == no_filters()
}

pub type AgentView {
  AgentView(agent: Agent, label: String, owner_handle: String, away: Bool)
}

pub type ItemView {
  ItemView(
    item: Item,
    agent_label: String,
    owner: Int,
    priority: Float,
    away: Bool,
    overlap: Option(#(Int, String, String)),
    seen_by: Option(String),
    hidden_by: Option(String),
    /// linked documents: ref (`model.doc_ref`) and title
    docs: List(#(String, String)),
    /// the item's thread, oldest first
    comments: List(CommentView),
    /// decisions: who answered last (the latest human comment)
    answered: Option(#(String, Int)),
  )
}

pub type CommentView {
  CommentView(
    comment: model.Comment,
    /// the commenter's handle, or the agent's label for an agent's reply
    author: String,
    by_agent: Bool,
  )
}

pub type GoalGroup {
  GoalGroup(
    primary: ItemView,
    others: List(ItemView),
    /// the shown tasks filed under any goal in the group, by priority
    tasks: List(ItemView),
  )
}

pub type View {
  View(
    agents: List(AgentView),
    blocking: List(ItemView),
    decisions: List(ItemView),
    decisions_more: Int,
    goals: List(GoalGroup),
    goals_more: Int,
    /// every shown task: those under a shown goal (also in its group's
    /// `tasks`) and the rest (also in `other_tasks`)
    tasks: List(ItemView),
    tasks_more: Int,
    /// shown tasks not filed under a shown goal
    other_tasks: List(ItemView),
    hidden: List(ItemView),
    filters: Filters,
    computed_at: Int,
  )
}

/// Previously visible item ids per zone, for hysteresis.
pub type Visible {
  Visible(goals: Set(Int), tasks: Set(Int), decisions: Set(Int))
}

pub fn no_visible() -> Visible {
  Visible(set.new(), set.new(), set.new())
}

const hysteresis = 0.05

const hour = 3_600_000.0

pub fn compute(
  s: State,
  display: config.Display,
  stale_threshold: Float,
  filters: Filters,
  previous: Visible,
  now: Int,
) -> #(View, Visible) {
  let away_ms = display.agent_away_after_minutes * 60_000
  let agent_ok = fn(agent: Agent) {
    let handle = state.handle_of(s, agent.owner)
    option.unwrap(option.map(filters.owner, fn(o) { o == handle }), True)
    && option.unwrap(
      option.map(filters.project, fn(p) { p == agent.project }),
      True,
    )
    && option.unwrap(option.map(filters.name, fn(n) { n == agent.name }), True)
  }
  let agents =
    dict.values(s.agents)
    |> list.filter(agent_ok)
  let agent_ids = set.from_list(list.map(agents, fn(a) { a.id }))
  let away = fn(agent_id: Int) {
    case dict.get(s.agents, agent_id) {
      Ok(a) -> now - a.last_seen_at > away_ms
      Error(_) -> True
    }
  }
  // An agent waiting on a human goes away, so its blockers stay.
  let shown = fn(i: Item) {
    !filters.hide_away
    || !away(i.agent)
    || { i.kind == model.Decision && i.blocking }
  }
  let open =
    state.open_items(s)
    |> list.filter(fn(i) { set.contains(agent_ids, i.agent) && shown(i) })
  let threads = threads(s)
  let view_of = fn(i: Item) {
    item_view(
      s,
      threads,
      i,
      priority(i, away(i.agent), stale_threshold, now),
      away(i.agent),
    )
  }
  let visible_items = list.filter(open, fn(i) { option.is_none(i.hidden_by) })
  let hidden =
    list.filter(open, fn(i) { option.is_some(i.hidden_by) })
    |> list.map(view_of)
    |> list.sort(fn(a, b) { int.compare(b.item.updated_at, a.item.updated_at) })

  // decisions: blockers always shown; unseen first, then seen, then
  // answered, oldest first within each
  let decisions =
    visible_items
    |> list.filter(fn(i) { i.kind == model.Decision })
    |> list.map(view_of)
  let attention = fn(v: ItemView) {
    case v.answered, v.seen_by {
      Some(_), _ -> 2
      None, Some(_) -> 1
      None, None -> 0
    }
  }
  let blocking =
    decisions
    |> list.filter(fn(v) { v.item.blocking })
    |> list.sort(fn(a, b) {
      case int.compare(attention(a), attention(b)) {
        order.Eq -> int.compare(a.item.created_at, b.item.created_at)
        o -> o
      }
    })
  let non_blocking = list.filter(decisions, fn(v) { !v.item.blocking })
  let expand = option.unwrap(filters.expand, "")
  let #(decisions_shown, decisions_more) =
    select(
      non_blocking,
      slots(expand == "decisions", display.slots_decisions),
      display.cap_decisions,
      previous.decisions,
    )

  let tasks =
    visible_items
    |> list.filter(fn(i) { i.kind == model.Task })
    |> list.map(view_of)
  let #(tasks_shown, tasks_more) =
    select(
      tasks,
      slots(expand == "tasks", display.slots_tasks),
      display.cap_tasks,
      previous.tasks,
    )

  // goals: any number per agent; overlapping goals merge into one group
  let goal_views =
    visible_items
    |> list.filter(fn(i) { i.kind == model.Goal })
    |> list.map(fn(g) {
      let agent_items =
        list.filter(open, fn(i) { i.agent == g.agent && i.kind != model.Goal })
      let best =
        agent_items
        |> list.map(fn(i) { priority(i, away(i.agent), stale_threshold, now) })
        |> list.max(float.compare)
        |> option.from_result
        |> option.unwrap(0.0)
      let recent = case dict.get(s.agents, g.agent) {
        Ok(a) if now - a.last_seen_at < 3_600_000 -> 0.2
        _ -> 0.0
      }
      item_view(s, threads, g, best +. recent, away(g.agent))
    })
  let groups = group_goals(goal_views)
  let #(goals_shown, goals_more) =
    select_groups(
      groups,
      slots(expand == "goals", display.slots_goals),
      previous.goals,
    )
  // shown tasks go under their shown goal's group, the rest stay apart
  let group_of =
    list.fold(goals_shown, dict.new(), fn(acc, g) {
      list.fold([g.primary, ..g.others], acc, fn(acc, member) {
        dict.insert(acc, member.item.id, g.primary.item.id)
      })
    })
  let under = fn(t: ItemView) {
    option.then(t.item.goal, fn(goal) {
      dict.get(group_of, goal) |> option.from_result
    })
  }
  let goals_shown =
    list.map(goals_shown, fn(g) {
      GoalGroup(
        ..g,
        tasks: list.filter(tasks_shown, fn(t) {
          under(t) == Some(g.primary.item.id)
        }),
      )
    })
  let other_tasks = list.filter(tasks_shown, fn(t) { under(t) == None })

  let agent_views =
    agents
    |> list.filter(fn(a) {
      { !filters.hide_away || !away(a.id) }
      && {
        list.any(open, fn(i) { i.agent == a.id })
        || now - a.last_seen_at < 86_400_000
      }
    })
    |> list.map(fn(a) {
      let handle = state.handle_of(s, a.owner)
      AgentView(
        agent: a,
        label: model.agent_label(handle, a),
        owner_handle: handle,
        away: away(a.id),
      )
    })
    |> list.sort(fn(a, b) {
      case a.away, b.away {
        False, True -> order.Lt
        True, False -> order.Gt
        _, _ -> string.compare(a.label, b.label)
      }
    })

  let view =
    View(
      agents: agent_views,
      blocking:,
      decisions: decisions_shown,
      decisions_more:,
      goals: goals_shown,
      goals_more:,
      tasks: tasks_shown,
      tasks_more:,
      other_tasks:,
      hidden:,
      filters:,
      computed_at: now,
    )
  let visible =
    Visible(
      goals: set.from_list(list.map(goals_shown, fn(g) { g.primary.item.id })),
      tasks: set.from_list(list.map(tasks_shown, fn(v) { v.item.id })),
      decisions: set.from_list(list.map(decisions_shown, fn(v) { v.item.id })),
    )
  #(view, visible)
}

fn slots(expanded: Bool, n: Int) -> Int {
  case expanded {
    True -> 100_000
    False -> n
  }
}

/// Priority per the design (§8). Blocking decisions are pinned elsewhere.
pub fn priority(
  item: Item,
  away: Bool,
  stale_threshold: Float,
  now: Int,
) -> Float {
  let imp = case item.importance {
    Some(score) -> score /. 3.0
    None -> 0.33
  }
  let fresh = exp(int.to_float(item.updated_at - now) /. { 6.0 *. hour })
  let wait =
    float.min(1.0, int.to_float(now - item.created_at) /. { 24.0 *. hour })
  let stale = case item.stale_p {
    Some(p) if p >=. stale_threshold -> p
    _ -> 0.0
  }
  let away_penalty = case away {
    True -> 0.3
    False -> 0.0
  }
  let seen = case item.seen_by {
    Some(_) -> 0.2
    None -> 0.0
  }
  case item.kind {
    model.Decision -> 0.6 *. imp +. 0.4 *. wait -. 0.5 *. stale -. seen
    _ -> 0.6 *. imp +. 0.4 *. fresh -. 0.5 *. stale -. away_penalty
  }
}

fn exp(x: Float) -> Float {
  case float.power(2.718281828459045, x) {
    Ok(v) -> v
    Error(_) -> 0.0
  }
}

/// Comments by item, each thread oldest first.
fn threads(s: State) -> dict.Dict(Int, List(model.Comment)) {
  dict.values(s.comments)
  |> list.sort(fn(a, b) { int.compare(b.id, a.id) })
  |> list.fold(dict.new(), fn(acc, c) {
    dict.upsert(acc, c.item, fn(existing) { [c, ..option.unwrap(existing, [])] })
  })
}

fn comment_view(s: State, c: model.Comment) -> CommentView {
  case c.author {
    model.HumanAuthor(user) ->
      CommentView(comment: c, author: state.handle_of(s, user), by_agent: False)
    model.AgentAuthor(agent) ->
      CommentView(
        comment: c,
        author: state.agent_label(s, agent),
        by_agent: True,
      )
  }
}

fn item_view(
  s: State,
  threads: dict.Dict(Int, List(model.Comment)),
  item: Item,
  priority: Float,
  away: Bool,
) -> ItemView {
  let comments =
    dict.get(threads, item.id)
    |> result.unwrap([])
    |> list.map(comment_view(s, _))
  let answered = case item.kind {
    model.Decision ->
      comments
      |> list.filter(fn(c) { !c.by_agent })
      |> list.last
      |> option.from_result
      |> option.map(fn(c) { #(c.author, c.comment.created_at) })
    _ -> None
  }
  let owner = case dict.get(s.agents, item.agent) {
    Ok(a) -> a.owner
    Error(_) -> 0
  }
  ItemView(
    item:,
    agent_label: state.agent_label(s, item.agent),
    owner:,
    priority:,
    away:,
    overlap: case item.overlaps {
      Some(other) ->
        case state.get_item(s, other) {
          Some(o) -> Some(#(o.id, o.title, state.agent_label(s, o.agent)))
          None -> None
        }
      None -> None
    },
    seen_by: option.map(item.seen_by, state.handle_of(s, _)),
    hidden_by: option.map(item.hidden_by, state.handle_of(s, _)),
    docs: list.filter_map(item.docs, fn(id) {
      case state.get_document(s, id) {
        Some(d) -> Ok(#(model.doc_ref(d), d.title))
        None -> Error(Nil)
      }
    }),
    comments:,
    answered:,
  )
}

fn by_priority(a: ItemView, b: ItemView) -> order.Order {
  case float.compare(b.priority, a.priority) {
    order.Eq -> int.compare(b.item.updated_at, a.item.updated_at)
    o -> o
  }
}

/// Greedy fill honouring a per-agent cap, then fill leftover slots ignoring
/// the cap. Previously visible items get a hysteresis bonus so a newcomer has
/// to beat them by a margin.
pub fn select(
  candidates: List(ItemView),
  slots: Int,
  cap: Int,
  previous: Set(Int),
) -> #(List(ItemView), Int) {
  let boosted =
    candidates
    |> list.map(fn(v) {
      case set.contains(previous, v.item.id) {
        True -> #(v, v.priority +. hysteresis)
        False -> #(v, v.priority)
      }
    })
    |> list.sort(fn(a, b) {
      case float.compare(b.1, a.1) {
        order.Eq ->
          int.compare({ b.0 }.item.updated_at, { a.0 }.item.updated_at)
        o -> o
      }
    })
    |> list.map(fn(pair) { pair.0 })
  let #(first, _) =
    list.fold(boosted, #([], dict.new()), fn(acc, v) {
      let #(chosen, counts) = acc
      let n =
        dict.get(counts, v.item.agent) |> option.from_result |> option.unwrap(0)
      case list.length(chosen) < slots && n < cap {
        True -> #([v, ..chosen], dict.insert(counts, v.item.agent, n + 1))
        False -> acc
      }
    })
  let chosen_ids = set.from_list(list.map(first, fn(v) { v.item.id }))
  let rest =
    list.filter(boosted, fn(v) { !set.contains(chosen_ids, v.item.id) })
  let room = int.max(slots - list.length(first), 0)
  let shown =
    list.append(first, list.take(rest, room)) |> list.sort(by_priority)
  #(shown, list.length(candidates) - list.length(shown))
}

/// Group goals linked by an overlap; the highest-priority goal is primary.
fn group_goals(goals: List(ItemView)) -> List(GoalGroup) {
  let ids = set.from_list(list.map(goals, fn(g) { g.item.id }))
  let root = fn(g: ItemView) {
    case g.item.overlaps {
      Some(other) ->
        case set.contains(ids, other) {
          True -> int.min(other, g.item.id)
          False -> g.item.id
        }
      None -> g.item.id
    }
  }
  goals
  |> list.group(root)
  |> dict.values
  |> list.map(fn(members) {
    let sorted = list.sort(members, by_priority)
    let assert [primary, ..others] = sorted
    GoalGroup(primary:, others:, tasks: [])
  })
  |> list.sort(fn(a, b) { by_priority(a.primary, b.primary) })
}

fn select_groups(
  groups: List(GoalGroup),
  slots: Int,
  previous: Set(Int),
) -> #(List(GoalGroup), Int) {
  let sorted =
    groups
    |> list.sort(fn(a, b) {
      let pa = a.primary.priority +. bonus(previous, a.primary.item.id)
      let pb = b.primary.priority +. bonus(previous, b.primary.item.id)
      float.compare(pb, pa)
    })
  let shown = list.take(sorted, slots)
  #(shown, list.length(groups) - list.length(shown))
}

fn bonus(previous: Set(Int), id: Int) -> Float {
  case set.contains(previous, id) {
    True -> hysteresis
    False -> 0.0
  }
}

/// Unseen open decisions posted by agents owned by `user_id`.
pub fn unseen_decisions_for(s: State, user_id: Int) -> Int {
  state.open_items(s)
  |> list.filter(fn(i) {
    i.kind == model.Decision
    && option.is_none(i.seen_by)
    && case dict.get(s.agents, i.agent) {
      Ok(a) -> a.owner == user_id
      Error(_) -> False
    }
  })
  |> list.length
}
