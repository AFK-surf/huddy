//// Review logic (pure): build decision-model requests for a write or a
//// sweep, and turn answers into findings. Findings are advice for the
//// agent; nothing here rejects or changes an item.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import huddy/config.{type Thresholds}
import huddy/fmt
import huddy/jev.{type Answer, type Question}
import huddy/model.{type Item, type State}
import huddy/similar
import huddy/state.{type NewFinding, NewFinding}

pub type Context {
  Context(
    item: Item,
    agent_label: String,
    /// ref -> item, for duplicate/overlap candidates
    similar: List(#(String, Item)),
    /// ref -> item, the agent's other open items (staleness questions)
    own_open: List(#(String, Item)),
    /// tasks: ref -> goal, the agent's open goals the task may serve
    goals: List(#(String, Item)),
    /// goals: ref -> task, the agent's open tasks not filed under an open
    /// goal, which may serve this one
    unfiled: List(#(String, Item)),
  )
}

/// Where write-review answers file tasks under goals.
pub type Filing {
  Filing(
    /// tasks: Some(Some(goal)) files it under that goal, Some(None) under
    /// none; None leaves it as it was (no confident answer)
    goal: Option(Option(Int)),
    /// goals: the unfiled tasks that serve it
    tasks: List(Int),
  )
}

pub type Request {
  Request(state: Json, questions: List(#(String, Question)), context: Context)
}

const importance_rubric = [
  "Routine; nobody needs to notice", "Normal progress worth a glance",
  "Notable: touches shared code, interfaces, or other people's work",
  "Critical: risk to production, data, security, or blocks others",
]

/// Staleness as a yes/no question naming both items: calibrated against the
/// live model, this separates finished/replaced items from unrelated ones far
/// better than a four-way choice (DESIGN.md §15).
fn stale_question(r: String, title: String, context: String) -> jev.Question {
  jev.Noul(
    context
      <> " Does it show that the agent's earlier item "
      <> r
      <> " (\""
      <> title
      <> "\") is already done, abandoned or replaced?",
    context_yes(r),
    r <> " is still open work, or the update is about something else",
  )
}

fn context_yes(r: String) -> String {
  "The update says or clearly implies that "
  <> r
  <> "'s work is complete, dropped or superseded"
}

/// P(stale) from a staleness answer (yes/no, or the older choice form).
fn stale_p(answer: Answer) -> Float {
  case answer {
    jev.NoulAnswer(p) -> p
    _ ->
      jev.probability(answer, "finished")
      +. jev.probability(answer, "superseded")
  }
}

fn ref(item: Item) -> String {
  model.item_ref(item.id)
}

fn item_brief(s: State, item: Item, now: Int) -> Json {
  json.object([
    #("ref", json.string(ref(item))),
    #("kind", json.string(model.kind_to_string(item.kind))),
    #("agent", json.string(state.agent_label(s, item.agent))),
    #("title", json.string(item.title)),
    #("state", json.string(model.state_to_string(item.state))),
    #("updated", json.string(fmt.ago(now, item.updated_at))),
  ])
}

fn current_goals(s: State, agent_id: Int) -> Json {
  state.open_items_of(s, agent_id)
  |> list.filter(fn(i) { i.kind == model.Goal })
  |> json.array(fn(g) { json.string(g.title) })
}

/// The one request made for a post or edit (§6.2).
pub fn write_request(s: State, item: Item, now: Int) -> Request {
  let agent_project = case dict.get(s.agents, item.agent) {
    Ok(a) -> a.project
    Error(_) -> ""
  }
  let candidates =
    state.open_items(s)
    |> list.filter(fn(i) { i.id != item.id && i.kind == item.kind })
  let similar_items =
    similar.top(
      item.title <> " " <> item.detail,
      candidates,
      fn(i) { i.title <> " " <> i.detail },
      fn(i) {
        case dict.get(s.agents, i.agent) {
          Ok(a) if a.project == agent_project -> 0.1
          _ -> 0.0
        }
      },
      0.08,
      8,
    )
  let own_open =
    state.open_items_of(s, item.agent)
    |> list.filter(fn(i) { i.id != item.id && i.kind != model.Goal })
    |> list.take(6)
  let new_item =
    json.object([
      #("kind", json.string(model.kind_to_string(item.kind))),
      #("title", json.string(item.title)),
      #("detail", json.string(item.detail)),
      #("options", json.array(item.options, json.string)),
      #("blocking", json.bool(item.blocking)),
    ])
  let label = state.agent_label(s, item.agent)
  let state_json =
    json.object([
      #("new_item", new_item),
      #("agent", json.string(label)),
      #("agent_goals", current_goals(s, item.agent)),
      #("agent_open_items", json.array(own_open, item_brief(s, _, now))),
      #("similar_items", json.array(similar_items, item_brief(s, _, now))),
    ])
  let base = [
    #(
      "readable",
      // Wording calibrated against the live model (see DESIGN.md §15).
      jev.Noul(
        "Could a teammate who has never seen this agent's session tell from new_item's title and detail what the work is?",
        "Specific enough to know what the work or question is",
        "Too vague, cryptic, or only meaningful inside the agent's session",
      ),
    ),
    #(
      "importance",
      jev.Score(
        "How much should the team's humans care about new_item right now?",
        importance_rubric,
      ),
    ),
  ]
  let decision_q = case item.kind {
    model.Decision -> [
      #(
        "answerable",
        jev.Noul(
          "Does new_item ask a concrete question that a human could answer with a choice or a short reply?",
          "It states a specific question or choice to make",
          "It is a status update or too vague to answer",
        ),
      ),
    ]
    _ -> []
  }
  let same_q = case similar_items {
    [] -> []
    _ -> [
      #(
        "same_as",
        jev.Choice(
          "Does an item in similar_items describe the same work or question as new_item?",
          list.append(
            list.map(similar_items, fn(i) {
              #(ref(i), state.agent_label(s, i.agent) <> ": " <> i.title)
            }),
            [#("none", "None of them describes the same work or question")],
          ),
        ),
      ),
    ]
  }
  // filing: which goal a task serves, and which unfiled tasks a goal takes
  let goals = case item.kind {
    model.Task ->
      state.open_items_of(s, item.agent)
      |> list.filter(fn(i) { i.kind == model.Goal })
      |> list.take(8)
    _ -> []
  }
  let goal_q = case goals {
    [] -> []
    _ -> [
      #(
        "goal",
        jev.Choice(
          "new_item is one of the agent's tasks. Which of the agent's goals is it a step towards?",
          list.append(list.map(goals, fn(g) { #(ref(g), g.title) }), [
            #("none", "None of them: the task is separate work"),
          ]),
        ),
      ),
    ]
  }
  let unfiled = case item.kind {
    model.Goal ->
      state.unfiled_tasks(s, item.agent)
      |> list.filter(fn(i) { i.id != item.id })
      |> list.take(6)
    _ -> []
  }
  let serves_q =
    list.map(unfiled, fn(t) {
      #(
        "serves_" <> ref(t),
        jev.Noul(
          "new_item is a goal the agent has set. Is the agent's task "
            <> ref(t)
            <> " (\""
            <> t.title
            <> "\") a step towards new_item?",
          "The task is part of the work towards new_item's end state",
          "The task is unrelated to new_item, or serves a different outcome",
        ),
      )
    })
  let stale_q =
    list.map(own_open, fn(i) {
      #(
        "stale_" <> ref(i),
        stale_question(
          ref(i),
          i.title,
          "new_item is the agent's latest update.",
        ),
      )
    })
  Request(
    state: state_json,
    questions: list.flatten([
      base,
      decision_q,
      same_q,
      stale_q,
      goal_q,
      serves_q,
    ]),
    context: Context(
      item:,
      agent_label: label,
      similar: list.map(similar_items, fn(i) { #(ref(i), i) }),
      own_open: list.map(own_open, fn(i) { #(ref(i), i) }),
      goals: list.map(goals, fn(i) { #(ref(i), i) }),
      unfiled: list.map(unfiled, fn(i) { #(ref(i), i) }),
    ),
  )
}

fn finding(
  item: Item,
  agent: Int,
  kind: model.FindingKind,
  confidence: Float,
  related: Option(Int),
  message: String,
  judgment: Int,
) -> NewFinding {
  NewFinding(
    agent:,
    item: Some(item.id),
    item_version: Some(item.version),
    related_item: related,
    kind:,
    confidence: Some(confidence),
    message:,
    judgment: Some(judgment),
  )
}

/// Turn write-review answers into an importance score and findings.
pub fn interpret_write(
  ctx: Context,
  answers: Dict(String, Answer),
  t: Thresholds,
  judgment: Int,
) -> #(Option(Float), List(NewFinding)) {
  let item = ctx.item
  let r = ref(item)
  let get = fn(name) { dict.get(answers, name) }
  let readable_findings = case get("readable") {
    Ok(jev.NoulAnswer(p)) if p <. t.unclear -> [
      finding(
        item,
        item.agent,
        model.Unclear,
        1.0 -. p,
        None,
        r
          <> " may be hard to follow for a teammate who hasn't seen your session. Say what and why in plain words; avoid file paths and jargon in the title.",
        judgment,
      ),
    ]
    _ -> []
  }
  let question_findings = case item.kind, get("answerable") {
    model.Decision, Ok(jev.NoulAnswer(p)) if p <. t.not_a_question -> [
      finding(
        item,
        item.agent,
        model.NotAQuestion,
        1.0 -. p,
        None,
        "Decision "
          <> r
          <> " doesn't state a question a human could answer. State the question and the options.",
        judgment,
      ),
    ]
    _, _ -> []
  }
  let same_findings = case get("same_as") {
    Ok(jev.ChoiceAnswer(choice:, ..) as answer) if choice != "none" -> {
      let confidence = choice_p(answer)
      case list.key_find(ctx.similar, choice) {
        Ok(other) if other.agent == item.agent && confidence >=. t.duplicate -> [
          finding(
            item,
            item.agent,
            model.Duplicate,
            confidence,
            Some(other.id),
            r
              <> " looks like your own "
              <> ref(other)
              <> " "
              <> fmt.quote(other.title)
              <> ". Consider updating "
              <> ref(other)
              <> " and dropping "
              <> r
              <> ".",
            judgment,
          ),
        ]
        Ok(other) if other.agent != item.agent && confidence >=. t.overlap -> [
          finding(
            item,
            item.agent,
            model.Overlap,
            confidence,
            Some(other.id),
            r
              <> " looks like another agent's "
              <> ref(other)
              <> " "
              <> fmt.quote(other.title)
              <> ".",
            judgment,
          ),
          finding(
            other,
            other.agent,
            model.Overlap,
            confidence,
            Some(item.id),
            "Your "
              <> ref(other)
              <> " looks like "
              <> ctx.agent_label
              <> "'s new "
              <> r
              <> " "
              <> fmt.quote(item.title)
              <> ".",
            judgment,
          ),
        ]
        _ -> []
      }
    }
    _ -> []
  }
  let stale_findings =
    list.filter_map(ctx.own_open, fn(pair) {
      let #(other_ref, other) = pair
      case get("stale_" <> other_ref) {
        Ok(answer) -> {
          let p = stale_p(answer)
          case p >=. t.stale {
            True ->
              Ok(finding(
                other,
                other.agent,
                model.Stale,
                float.min(p, 1.0),
                Some(item.id),
                other_ref
                  <> " "
                  <> fmt.quote(other.title)
                  <> " may be finished or superseded, given your later update "
                  <> r
                  <> ".",
                judgment,
              ))
            False -> Error(Nil)
          }
        }
        Error(_) -> Error(Nil)
      }
    })
  let importance = case get("importance") {
    Ok(jev.ScoreAnswer(score:, ..)) -> Some(float.clamp(score, 0.0, 3.0))
    _ -> None
  }
  #(
    importance,
    list.flatten([
      readable_findings,
      question_findings,
      same_findings,
      stale_findings,
    ]),
  )
}

/// Turn write-review answers into where tasks are filed: under which goal
/// a task goes, and which unfiled tasks a goal takes. Answers below the
/// `goal` threshold change nothing.
pub fn interpret_filing(
  ctx: Context,
  answers: Dict(String, Answer),
  t: Thresholds,
) -> Filing {
  let goal = case dict.get(answers, "goal") {
    Ok(jev.ChoiceAnswer(choice:, ..) as answer) ->
      case choice_p(answer) >=. t.goal, choice {
        False, _ -> None
        True, "none" -> Some(None)
        True, r ->
          list.key_find(ctx.goals, r)
          |> result.map(fn(g) { Some(Some(g.id)) })
          |> result.unwrap(None)
      }
    _ -> None
  }
  let tasks =
    list.filter_map(ctx.unfiled, fn(pair) {
      case dict.get(answers, "serves_" <> pair.0) {
        Ok(jev.NoulAnswer(p)) if p >=. t.goal -> Ok({ pair.1 }.id)
        _ -> Error(Nil)
      }
    })
  Filing(goal:, tasks:)
}

// --- sweep -----------------------------------------------------------------------

pub type SweepRequest {
  SweepRequest(
    agent: Int,
    state: Json,
    questions: List(#(String, Question)),
    open: List(#(String, Item)),
  )
}

/// One request per idle agent: staleness of each open task/decision, given
/// the agent's recent items (including closed ones).
pub fn sweep_request(
  s: State,
  agent_id: Int,
  now: Int,
) -> Option(SweepRequest) {
  let open =
    state.open_items_of(s, agent_id)
    |> list.filter(fn(i) { i.kind != model.Goal })
    |> list.take(10)
  case open {
    [] -> None
    _ -> {
      let recent = state.items_of(s, agent_id) |> list.take(10)
      let state_json =
        json.object([
          #("agent", json.string(state.agent_label(s, agent_id))),
          #("agent_goals", current_goals(s, agent_id)),
          #("open_items", json.array(open, item_brief(s, _, now))),
          #("recent_items", json.array(recent, item_brief(s, _, now))),
        ])
      let questions =
        list.map(open, fn(i) {
          #(
            "stale_" <> ref(i),
            stale_question(
              ref(i),
              i.title,
              "recent_items are the agent's latest items.",
            ),
          )
        })
      Some(SweepRequest(
        agent: agent_id,
        state: state_json,
        questions:,
        open: list.map(open, fn(i) { #(ref(i), i) }),
      ))
    }
  }
}

pub fn interpret_sweep(
  req: SweepRequest,
  answers: Dict(String, Answer),
  t: Thresholds,
  judgment: Int,
) -> List(NewFinding) {
  list.filter_map(req.open, fn(pair) {
    let #(r, item) = pair
    case dict.get(answers, "stale_" <> r) {
      Ok(answer) -> {
        let p = stale_p(answer)
        case p >=. t.stale {
          True ->
            Ok(finding(
              item,
              item.agent,
              model.Stale,
              float.min(p, 1.0),
              None,
              r
                <> " "
                <> fmt.quote(item.title)
                <> " may be finished or superseded, given your recent activity.",
              judgment,
            ))
          False -> Error(Nil)
        }
      }
      Error(_) -> Error(Nil)
    }
  })
}

// --- deterministic checks -----------------------------------------------------------

/// `too_many_open` for an agent, or None when within the guidelines.
pub fn too_many_open(
  s: State,
  agent_id: Int,
  tasks_guideline: Int,
  decisions_guideline: Int,
) -> Option(NewFinding) {
  let open = state.open_items_of(s, agent_id)
  let tasks = list.count(open, fn(i) { i.kind == model.Task })
  let decisions = list.count(open, fn(i) { i.kind == model.Decision })
  let parts =
    list.flatten([
      case tasks > tasks_guideline {
        True -> [
          int.to_string(tasks)
          <> " open tasks (guideline: "
          <> int.to_string(tasks_guideline)
          <> ")",
        ]
        False -> []
      },
      case decisions > decisions_guideline {
        True -> [
          int.to_string(decisions)
          <> " open decisions (guideline: "
          <> int.to_string(decisions_guideline)
          <> ")",
        ]
        False -> []
      },
    ])
  case parts {
    [] -> None
    _ ->
      Some(NewFinding(
        agent: agent_id,
        item: None,
        item_version: None,
        related_item: None,
        kind: model.TooManyOpen,
        confidence: None,
        message: "You have "
          <> string.join(parts, " and ")
          <> ". Close finished ones to keep the report concise.",
        judgment: None,
      ))
  }
}

/// `untouched` findings for open items not updated within `days`.
pub fn untouched(s: State, days: Int, now: Int) -> List(NewFinding) {
  let cutoff = now - state.days(days)
  state.open_items(s)
  |> list.filter(fn(i) { i.updated_at < cutoff })
  |> list.map(fn(i) {
    NewFinding(
      agent: i.agent,
      item: Some(i.id),
      item_version: Some(i.version),
      related_item: None,
      kind: model.Untouched,
      confidence: None,
      message: ref(i)
        <> " "
        <> fmt.quote(i.title)
        <> " hasn't changed in "
        <> int.to_string(days)
        <> " days. Update it, or close it if it's done.",
      judgment: None,
    )
  })
}

/// The probability of the chosen option. (The API's separate `confidence`
/// field is a different, lower-scaled measure; thresholds are probabilities.)
fn choice_p(answer: Answer) -> Float {
  case answer {
    jev.ChoiceAnswer(choice:, confidence:, probabilities:) ->
      dict.get(probabilities, choice) |> result.unwrap(confidence)
    _ -> 0.0
  }
}
