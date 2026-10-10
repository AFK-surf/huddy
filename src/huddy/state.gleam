//// Pure operations on `State`. The store actor is the only caller; every
//// function here is deterministic given its inputs (time is passed in).

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import huddy/model.{
  type Agent, type Finding, type FindingKind, type Item, type ItemState,
  type Kind, type McpLink, type OAuthGrant, type OAuthToken, type State,
  type User, Agent, Event, Finding, Item, Judgment, McpLink, OAuthGrant,
  OAuthToken, State, User, WebSession,
}

const day_ms = 86_400_000

const hour_ms = 3_600_000

// --- ids & events ------------------------------------------------------------

fn bump(
  state: State,
  field: fn(model.NextIds) -> #(Int, model.NextIds),
) -> #(State, Int) {
  let #(id, next) = field(state.next_id)
  #(State(..state, next_id: next), id)
}

pub fn add_event(
  state: State,
  now: Int,
  actor: String,
  item: Option(Int),
  event_type: String,
  detail: String,
) -> State {
  let #(state, id) =
    bump(state, fn(n) { #(n.event, model.NextIds(..n, event: n.event + 1)) })
  State(..state, events: [
    Event(id:, at: now, actor:, item:, event_type:, detail:),
    ..state.events
  ])
}

pub fn agent_actor(agent_id: Int) -> String {
  "agent:" <> int.to_string(agent_id)
}

pub fn user_actor(user_id: Int) -> String {
  "user:" <> int.to_string(user_id)
}

// --- users & sessions -----------------------------------------------------------

pub fn user_by_email(state: State, email: String) -> Option(User) {
  let email = string.lowercase(email)
  dict.values(state.users)
  |> list.find(fn(u) { u.email == email })
  |> option.from_result
}

pub fn user_by_handle(state: State, handle: String) -> Option(User) {
  dict.values(state.users)
  |> list.find(fn(u) { u.handle == handle })
  |> option.from_result
}

pub fn user(state: State, id: Int) -> Option(User) {
  dict.get(state.users, id) |> option.from_result
}

pub fn handle_of(state: State, user_id: Int) -> String {
  case dict.get(state.users, user_id) {
    Ok(u) -> u.handle
    Error(_) -> "?"
  }
}

/// Lowercase, keep [a-z0-9._-], collapse everything else to "-", max 40 chars.
pub fn slug(text: String) -> String {
  text
  |> string.lowercase
  |> string.to_graphemes
  |> list.map(fn(c) {
    case is_slug_char(c) {
      True -> c
      False -> "-"
    }
  })
  |> string.concat
  |> collapse_dashes
  |> trim_dashes
  |> string.slice(0, 40)
}

fn is_slug_char(c: String) -> Bool {
  case c {
    "." | "_" | "-" -> True
    _ ->
      case string.to_utf_codepoints(c) {
        [cp] -> {
          let n = string.utf_codepoint_to_int(cp)
          { n >= 97 && n <= 122 } || { n >= 48 && n <= 57 }
        }
        _ -> False
      }
  }
}

fn collapse_dashes(s: String) -> String {
  case string.contains(s, "--") {
    True -> collapse_dashes(string.replace(s, "--", "-"))
    False -> s
  }
}

fn trim_dashes(s: String) -> String {
  let s = case string.starts_with(s, "-") {
    True -> trim_dashes(string.drop_start(s, 1))
    False -> s
  }
  case string.ends_with(s, "-") {
    True -> trim_dashes(string.drop_end(s, 1))
    False -> s
  }
}

pub fn is_valid_slug(text: String) -> Bool {
  text != "" && slug(text) == text
}

fn unique_handle(state: State, base: String, n: Int) -> String {
  let candidate = case n {
    1 -> base
    _ -> base <> "-" <> int.to_string(n)
  }
  case user_by_handle(state, candidate) {
    Some(_) -> unique_handle(state, base, n + 1)
    None -> candidate
  }
}

pub fn create_user(state: State, email: String, now: Int) -> #(State, User) {
  let email = string.lowercase(string.trim(email))
  let local = case string.split_once(email, "@") {
    Ok(#(local, _)) -> local
    Error(_) -> email
  }
  let base = case slug(local) {
    "" -> "user"
    s -> s
  }
  let handle = unique_handle(state, base, 1)
  let #(state, id) =
    bump(state, fn(n) { #(n.user, model.NextIds(..n, user: n.user + 1)) })
  let user =
    User(
      id:,
      email:,
      handle:,
      notify_browser_non_blocking: False,
      created_at: now,
      last_login_at: None,
    )
  let state = State(..state, users: dict.insert(state.users, id, user))
  #(add_event(state, now, user_actor(id), None, "user_created", handle), user)
}

pub fn touch_login(state: State, user_id: Int, now: Int) -> State {
  update_user(state, user_id, fn(u) { User(..u, last_login_at: Some(now)) })
}

fn update_user(state: State, id: Int, f: fn(User) -> User) -> State {
  case dict.get(state.users, id) {
    Ok(u) -> State(..state, users: dict.insert(state.users, id, f(u)))
    Error(_) -> state
  }
}

pub fn set_handle(
  state: State,
  user_id: Int,
  handle: String,
) -> Result(State, String) {
  case is_valid_slug(handle) {
    False ->
      Error("Handles use lowercase letters, digits, '.', '_' and '-' (max 40).")
    True ->
      case user_by_handle(state, handle) {
        Some(other) if other.id != user_id -> Error("That handle is taken.")
        _ -> Ok(update_user(state, user_id, fn(u) { User(..u, handle:) }))
      }
  }
}

pub fn set_notify(
  state: State,
  user_id: Int,
  browser_non_blocking: Bool,
) -> State {
  update_user(state, user_id, fn(u) {
    User(..u, notify_browser_non_blocking: browser_non_blocking)
  })
}

pub fn create_session(
  state: State,
  token_sha256: String,
  user: Int,
  now: Int,
  ttl_ms: Int,
  user_agent: String,
) -> State {
  let session =
    WebSession(
      token_sha256:,
      user:,
      created_at: now,
      expires_at: now + ttl_ms,
      user_agent: string.slice(user_agent, 0, 200),
    )
  State(
    ..state,
    web_sessions: dict.insert(state.web_sessions, token_sha256, session),
  )
}

pub fn delete_session(state: State, token_sha256: String) -> State {
  State(..state, web_sessions: dict.delete(state.web_sessions, token_sha256))
}

pub fn session_user(
  state: State,
  token_sha256: String,
  now: Int,
) -> Option(User) {
  case dict.get(state.web_sessions, token_sha256) {
    Ok(s) if s.expires_at > now -> user(state, s.user)
    _ -> None
  }
}

// --- agents -------------------------------------------------------------------

pub fn find_agent(
  state: State,
  owner: Int,
  name: String,
  project: String,
) -> Option(Agent) {
  dict.values(state.agents)
  |> list.find(fn(a) {
    a.owner == owner && a.name == name && a.project == project
  })
  |> option.from_result
}

pub fn ensure_agent(
  state: State,
  owner: Int,
  name: String,
  project: String,
  now: Int,
) -> #(State, Agent) {
  case find_agent(state, owner, name, project) {
    Some(agent) -> {
      let agent = Agent(..agent, last_seen_at: now)
      #(
        State(..state, agents: dict.insert(state.agents, agent.id, agent)),
        agent,
      )
    }
    None -> {
      let #(state, id) =
        bump(state, fn(n) { #(n.agent, model.NextIds(..n, agent: n.agent + 1)) })
      let agent =
        Agent(id:, owner:, name:, project:, created_at: now, last_seen_at: now)
      let state = State(..state, agents: dict.insert(state.agents, id, agent))
      #(
        add_event(
          state,
          now,
          agent_actor(id),
          None,
          "agent_created",
          name <> "/" <> project,
        ),
        agent,
      )
    }
  }
}

pub fn touch_agent(state: State, agent_id: Int, now: Int) -> State {
  case dict.get(state.agents, agent_id) {
    Ok(a) ->
      State(
        ..state,
        agents: dict.insert(
          state.agents,
          agent_id,
          Agent(..a, last_seen_at: now),
        ),
      )
    Error(_) -> state
  }
}

pub fn agent_label(state: State, agent_id: Int) -> String {
  case dict.get(state.agents, agent_id) {
    Ok(a) -> model.agent_label(handle_of(state, a.owner), a)
    Error(_) -> "?"
  }
}

// --- items --------------------------------------------------------------------

pub fn get_item(state: State, id: Int) -> Option(Item) {
  dict.get(state.items, id) |> option.from_result
}

fn put_item(state: State, item: Item) -> State {
  State(..state, items: dict.insert(state.items, item.id, item))
}

pub fn open_items_of(state: State, agent_id: Int) -> List(Item) {
  dict.values(state.items)
  |> list.filter(fn(i) { i.agent == agent_id && model.is_open(i) })
  |> list.sort(fn(a, b) { int.compare(b.updated_at, a.updated_at) })
}

pub fn items_of(state: State, agent_id: Int) -> List(Item) {
  dict.values(state.items)
  |> list.filter(fn(i) { i.agent == agent_id })
  |> list.sort(fn(a, b) { int.compare(b.updated_at, a.updated_at) })
}

pub fn open_items(state: State) -> List(Item) {
  dict.values(state.items) |> list.filter(model.is_open)
}

pub type NewItem {
  NewItem(
    kind: Kind,
    title: String,
    detail: String,
    blocking: Bool,
    options: List(String),
  )
}

/// Create an item. A new goal replaces the agent's current active goal.
pub fn create_item(
  state: State,
  agent_id: Int,
  new: NewItem,
  now: Int,
) -> #(State, Item) {
  let state = case new.kind {
    model.Goal ->
      open_items_of(state, agent_id)
      |> list.filter(fn(i) { i.kind == model.Goal })
      |> list.fold(state, fn(s, goal) {
        close_item(s, goal, model.Replaced, now, agent_actor(agent_id))
      })
    _ -> state
  }
  let #(state, id) =
    bump(state, fn(n) { #(n.item, model.NextIds(..n, item: n.item + 1)) })
  let item =
    Item(
      id:,
      agent: agent_id,
      kind: new.kind,
      title: new.title,
      detail: new.detail,
      blocking: new.kind == model.Decision && new.blocking,
      options: case new.kind {
        model.Decision -> new.options
        _ -> []
      },
      state: model.initial_state(new.kind),
      importance: None,
      reviewed_at: None,
      stale_p: None,
      overlaps: None,
      flagged: False,
      seen_by: None,
      seen_at: None,
      hidden_by: None,
      hidden_note: None,
      version: 1,
      created_at: now,
      updated_at: now,
      closed_at: None,
    )
  let state =
    put_item(state, item)
    |> touch_agent(agent_id, now)
    |> add_event(
      now,
      agent_actor(agent_id),
      Some(id),
      "item_posted",
      model.kind_to_string(new.kind) <> ": " <> new.title,
    )
  #(state, item)
}

pub type Edit {
  Edit(
    title: Option(String),
    detail: Option(String),
    blocking: Option(Bool),
    options: Option(List(String)),
    state: Option(ItemState),
  )
}

pub type EditOutcome {
  EditOutcome(item: Item, content_changed: Bool)
}

/// Apply an agent's edit to its own item.
pub fn edit_item(
  state: State,
  agent_id: Int,
  id: Int,
  edit: Edit,
  now: Int,
) -> Result(#(State, EditOutcome), String) {
  use item <- result.try(
    get_item(state, id)
    |> option.to_result("No item " <> model.item_ref(id) <> "."),
  )
  use _ <- result.try(case item.agent == agent_id {
    True -> Ok(Nil)
    False ->
      Error(
        model.item_ref(id)
        <> " belongs to "
        <> agent_label(state, item.agent)
        <> "; agents can only change their own items.",
      )
  })
  use _ <- result.try(case model.is_open(item) {
    True -> Ok(Nil)
    False ->
      Error(
        model.item_ref(id)
        <> " is already closed ("
        <> model.state_to_string(item.state)
        <> ").",
      )
  })
  use new_state <- result.try(case edit.state {
    None -> Ok(None)
    Some(s) if s == item.state -> Ok(None)
    Some(s) ->
      case list.contains(model.closing_states(item.kind), s) {
        True -> Ok(Some(s))
        False ->
          Error(
            "A "
            <> model.kind_to_string(item.kind)
            <> " can move to: "
            <> model.closing_states(item.kind)
            |> list.map(model.state_to_string)
            |> string.join(", ")
            <> ".",
          )
      }
  })
  let title = option.unwrap(edit.title, item.title)
  let detail = option.unwrap(edit.detail, item.detail)
  let blocking = case item.kind {
    model.Decision -> option.unwrap(edit.blocking, item.blocking)
    _ -> False
  }
  let options = case item.kind {
    model.Decision -> option.unwrap(edit.options, item.options)
    _ -> []
  }
  let content_changed =
    title != item.title
    || detail != item.detail
    || blocking != item.blocking
    || options != item.options
  let actor = agent_actor(agent_id)
  let state = case content_changed {
    True -> {
      let updated =
        Item(
          ..item,
          title:,
          detail:,
          blocking:,
          options:,
          version: item.version + 1,
          updated_at: now,
        )
      put_item(state, updated)
      |> resolve_findings_for_item(id, now)
      |> add_event(now, actor, Some(id), "item_edited", title)
    }
    False -> state
  }
  let state = case new_state {
    Some(s) -> {
      let current = get_item(state, id) |> option.unwrap(item)
      close_item(state, current, s, now, actor)
    }
    None -> state
  }
  let state = touch_agent(state, agent_id, now)
  let final = get_item(state, id) |> option.unwrap(item)
  Ok(#(state, EditOutcome(item: final, content_changed:)))
}

/// Close an item: set the final state, resolve its findings and any
/// duplicate/overlap findings that point at it.
fn close_item(
  state: State,
  item: Item,
  to: ItemState,
  now: Int,
  actor: String,
) -> State {
  let closed = Item(..item, state: to, closed_at: Some(now), updated_at: now)
  let state =
    put_item(state, closed)
    |> resolve_findings_for_item(item.id, now)
  // findings elsewhere that reference this item as "related"
  let related =
    dict.values(state.findings)
    |> list.filter(fn(f) {
      model.finding_is_live(f)
      && f.related_item == Some(item.id)
      && { f.kind == model.Overlap || f.kind == model.Duplicate }
    })
  let state =
    list.fold(related, state, fn(s, f) {
      let s =
        put_finding(
          s,
          Finding(..f, status: model.FindingResolved, closed_at: Some(now)),
        )
      case f.item {
        Some(other) -> refresh_flags(s, other)
        None -> s
      }
    })
  add_event(
    state,
    now,
    actor,
    Some(item.id),
    "item_closed",
    model.state_to_string(to),
  )
}

pub fn mark_seen(
  state: State,
  item_id: Int,
  user_id: Int,
  now: Int,
) -> Result(State, String) {
  case get_item(state, item_id) {
    Some(i) if i.kind == model.Decision ->
      Ok(
        put_item(state, Item(..i, seen_by: Some(user_id), seen_at: Some(now)))
        |> add_event(
          now,
          user_actor(user_id),
          Some(item_id),
          "decision_seen",
          "",
        ),
      )
    Some(_) -> Error("Only decisions can be marked seen.")
    None -> Error("No such item.")
  }
}

pub fn hide(
  state: State,
  item_id: Int,
  user_id: Int,
  note: String,
  now: Int,
) -> Result(State, String) {
  case get_item(state, item_id) {
    Some(i) -> {
      let note = string.trim(note)
      let state =
        put_item(
          state,
          Item(..i, hidden_by: Some(user_id), hidden_note: case note {
            "" -> None
            n -> Some(n)
          }),
        )
      let who = handle_of(state, user_id)
      let message =
        who
        <> " hid "
        <> model.item_ref(item_id)
        <> " from the display"
        <> case note {
          "" -> "."
          n -> ": \"" <> n <> "\""
        }
      let #(state, _) =
        add_finding(
          state,
          NewFinding(
            agent: i.agent,
            item: Some(item_id),
            item_version: Some(i.version),
            related_item: None,
            kind: model.Hidden,
            confidence: None,
            message:,
            judgment: None,
          ),
          now,
          0,
        )
      Ok(add_event(
        state,
        now,
        user_actor(user_id),
        Some(item_id),
        "item_hidden",
        note,
      ))
    }
    None -> Error("No such item.")
  }
}

pub fn unhide(
  state: State,
  item_id: Int,
  user_id: Int,
  now: Int,
) -> Result(State, String) {
  case get_item(state, item_id) {
    Some(i) ->
      Ok(
        put_item(state, Item(..i, hidden_by: None, hidden_note: None))
        |> add_event(
          now,
          user_actor(user_id),
          Some(item_id),
          "item_unhidden",
          "",
        ),
      )
    None -> Error("No such item.")
  }
}

pub fn set_review_result(
  state: State,
  item_id: Int,
  version: Int,
  importance: Option(Float),
  now: Int,
) -> State {
  case get_item(state, item_id) {
    Some(i) if i.version == version ->
      put_item(
        state,
        Item(
          ..i,
          importance: option.or(importance, i.importance),
          reviewed_at: Some(now),
        ),
      )
    _ -> state
  }
}

// --- findings -----------------------------------------------------------------

pub type NewFinding {
  NewFinding(
    agent: Int,
    item: Option(Int),
    item_version: Option(Int),
    related_item: Option(Int),
    kind: FindingKind,
    confidence: Option(Float),
    message: String,
    judgment: Option(Int),
  )
}

fn put_finding(state: State, f: Finding) -> State {
  State(..state, findings: dict.insert(state.findings, f.id, f))
}

/// Add a finding unless an equivalent one is already live, or was dismissed
/// for the same item version (or, for `stale`, within the cooldown).
pub fn add_finding(
  state: State,
  new: NewFinding,
  now: Int,
  dismiss_cooldown_ms: Int,
) -> #(State, Option(Finding)) {
  let same = fn(f: Finding) {
    f.agent == new.agent
    && f.kind == new.kind
    && f.item == new.item
    && f.related_item == new.related_item
  }
  let blocked =
    dict.values(state.findings)
    |> list.any(fn(f) {
      same(f)
      && case f.status {
        model.FindingOpen | model.Delivered -> True
        model.Dismissed ->
          case new.kind {
            model.Stale ->
              now - option.unwrap(f.closed_at, f.created_at)
              < dismiss_cooldown_ms
            _ -> f.item_version == new.item_version
          }
        model.FindingResolved -> False
      }
    })
  case blocked {
    True -> #(state, None)
    False -> {
      let #(state, id) =
        bump(state, fn(n) {
          #(n.finding, model.NextIds(..n, finding: n.finding + 1))
        })
      let finding =
        Finding(
          id:,
          agent: new.agent,
          item: new.item,
          item_version: new.item_version,
          related_item: new.related_item,
          kind: new.kind,
          confidence: new.confidence,
          message: new.message,
          judgment: new.judgment,
          status: model.FindingOpen,
          dismiss_reason: None,
          created_at: now,
          delivered_at: None,
          closed_at: None,
        )
      let state = put_finding(state, finding)
      let state = case new.item {
        Some(item_id) -> refresh_flags(state, item_id)
        None -> state
      }
      #(state, Some(finding))
    }
  }
}

fn resolve_findings_for_item(state: State, item_id: Int, now: Int) -> State {
  let state =
    dict.values(state.findings)
    |> list.filter(fn(f) { model.finding_is_live(f) && f.item == Some(item_id) })
    |> list.fold(state, fn(s, f) {
      put_finding(
        s,
        Finding(..f, status: model.FindingResolved, closed_at: Some(now)),
      )
    })
  refresh_flags(state, item_id)
}

/// Recompute an item's cached display flags from its live findings.
pub fn refresh_flags(state: State, item_id: Int) -> State {
  case get_item(state, item_id) {
    None -> state
    Some(i) -> {
      let live =
        dict.values(state.findings)
        |> list.filter(fn(f) {
          model.finding_is_live(f) && f.item == Some(item_id)
        })
      let stale_p =
        live
        |> list.filter(fn(f) { f.kind == model.Stale })
        |> list.filter_map(fn(f) { option.to_result(f.confidence, Nil) })
        |> list.max(float.compare)
        |> option.from_result
      let overlaps =
        live
        |> list.find(fn(f) { f.kind == model.Overlap })
        |> result.map(fn(f) { f.related_item })
        |> result.unwrap(None)
      let flagged = list.any(live, fn(f) { f.kind == model.Injection })
      put_item(state, Item(..i, stale_p:, overlaps:, flagged:))
    }
  }
}

pub fn live_findings_for_agent(state: State, agent_id: Int) -> List(Finding) {
  dict.values(state.findings)
  |> list.filter(fn(f) { f.agent == agent_id && model.finding_is_live(f) })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

/// Undelivered findings for an agent; marks them delivered.
pub fn take_inbox(
  state: State,
  agent_id: Int,
  now: Int,
) -> #(State, List(Finding)) {
  let fresh =
    dict.values(state.findings)
    |> list.filter(fn(f) {
      f.agent == agent_id && f.status == model.FindingOpen
    })
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
  let state =
    list.fold(fresh, state, fn(s, f) {
      put_finding(
        s,
        Finding(..f, status: model.Delivered, delivered_at: Some(now)),
      )
    })
  #(state, fresh)
}

pub fn mark_delivered(state: State, ids: List(Int), now: Int) -> State {
  list.fold(ids, state, fn(s, id) {
    case dict.get(s.findings, id) {
      Ok(f) if f.status == model.FindingOpen ->
        put_finding(
          s,
          Finding(..f, status: model.Delivered, delivered_at: Some(now)),
        )
      _ -> s
    }
  })
}

pub fn dismiss_findings(
  state: State,
  agent_id: Int,
  ids: List(Int),
  reason: String,
  now: Int,
) -> Result(State, String) {
  list.try_fold(ids, state, fn(s, id) {
    case dict.get(s.findings, id) {
      Error(_) -> Error("No finding " <> model.finding_ref(id) <> ".")
      Ok(f) if f.agent != agent_id ->
        Error(model.finding_ref(id) <> " is addressed to another agent.")
      Ok(f) ->
        case model.finding_is_live(f) {
          False -> Ok(s)
          True -> {
            let s =
              put_finding(
                s,
                Finding(
                  ..f,
                  status: model.Dismissed,
                  dismiss_reason: Some(reason),
                  closed_at: Some(now),
                ),
              )
            let s = case f.item {
              Some(item_id) -> refresh_flags(s, item_id)
              None -> s
            }
            Ok(add_event(
              s,
              now,
              agent_actor(agent_id),
              f.item,
              "finding_dismissed",
              model.finding_kind_to_string(f.kind) <> ": " <> reason,
            ))
          }
        }
    }
  })
}

// --- judgments ----------------------------------------------------------------

pub fn add_judgment(
  state: State,
  now: Int,
  purpose: String,
  item: Option(Int),
  request: String,
  response: Option(String),
  latency_ms: Int,
  input_tokens: Int,
  output_tokens: Int,
  error: Option(String),
) -> #(State, Int) {
  let #(state, id) =
    bump(state, fn(n) {
      #(n.judgment, model.NextIds(..n, judgment: n.judgment + 1))
    })
  let j =
    Judgment(
      id:,
      at: now,
      purpose:,
      item:,
      request: Some(request),
      response:,
      latency_ms:,
      input_tokens:,
      output_tokens:,
      error:,
    )
  #(State(..state, judgments: dict.insert(state.judgments, id, j)), id)
}

/// Input tokens used since `since` (for the footer's monthly figure).
pub fn tokens_since(state: State, since: Int) -> Int {
  dict.values(state.judgments)
  |> list.filter(fn(j) { j.at >= since })
  |> list.fold(0, fn(acc, j) { acc + j.input_tokens + j.output_tokens })
}

// --- MCP secret links -----------------------------------------------------------

pub fn create_link(
  state: State,
  user_id: Int,
  secret_sha256: String,
  label: String,
  pinned_name: Option(String),
  pinned_project: Option(String),
  scope: String,
  now: Int,
) -> #(State, McpLink) {
  let #(state, id) =
    bump(state, fn(n) { #(n.link, model.NextIds(..n, link: n.link + 1)) })
  let link =
    McpLink(
      id:,
      user: user_id,
      secret_sha256:,
      label:,
      pinned_name:,
      pinned_project:,
      scope:,
      created_at: now,
      last_used_at: None,
      revoked_at: None,
    )
  let state = State(..state, mcp_links: dict.insert(state.mcp_links, id, link))
  #(
    add_event(state, now, user_actor(user_id), None, "link_created", label),
    link,
  )
}

pub fn link_by_secret(state: State, secret_sha256: String) -> Option(McpLink) {
  dict.values(state.mcp_links)
  |> list.find(fn(l) {
    option.is_none(l.revoked_at) && l.secret_sha256 == secret_sha256
  })
  |> option.from_result
}

pub fn touch_link(state: State, link_id: Int, now: Int) -> State {
  case dict.get(state.mcp_links, link_id) {
    Ok(l) ->
      State(
        ..state,
        mcp_links: dict.insert(
          state.mcp_links,
          link_id,
          McpLink(..l, last_used_at: Some(now)),
        ),
      )
    Error(_) -> state
  }
}

pub fn revoke_link(
  state: State,
  link_id: Int,
  user_id: Int,
  now: Int,
) -> State {
  case dict.get(state.mcp_links, link_id) {
    Ok(l) if l.user == user_id && l.revoked_at == None ->
      State(
        ..state,
        mcp_links: dict.insert(
          state.mcp_links,
          link_id,
          McpLink(..l, revoked_at: Some(now)),
        ),
      )
      |> add_event(now, user_actor(user_id), None, "link_revoked", l.label)
    _ -> state
  }
}

pub fn links_of(state: State, user_id: Int) -> List(McpLink) {
  dict.values(state.mcp_links)
  |> list.filter(fn(l) { l.user == user_id && option.is_none(l.revoked_at) })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

// --- OAuth --------------------------------------------------------------------

pub fn put_client(state: State, client: model.OAuthClient) -> State {
  State(
    ..state,
    oauth_clients: dict.insert(state.oauth_clients, client.client_id, client),
  )
}

pub fn client(state: State, client_id: String) -> Option(model.OAuthClient) {
  dict.get(state.oauth_clients, client_id) |> option.from_result
}

/// Find the user's live grant for a client, or create one; widen its scope.
pub fn ensure_grant(
  state: State,
  client_id: String,
  user_id: Int,
  scope: String,
  now: Int,
) -> #(State, OAuthGrant) {
  let existing =
    dict.values(state.oauth_grants)
    |> list.find(fn(g) {
      g.client_id == client_id
      && g.user == user_id
      && option.is_none(g.revoked_at)
    })
  case existing {
    Ok(g) -> {
      let g = OAuthGrant(..g, scope: merge_scopes(g.scope, scope))
      #(
        State(..state, oauth_grants: dict.insert(state.oauth_grants, g.id, g)),
        g,
      )
    }
    Error(_) -> {
      let #(state, id) =
        bump(state, fn(n) { #(n.grant, model.NextIds(..n, grant: n.grant + 1)) })
      let g =
        OAuthGrant(
          id:,
          client_id:,
          user: user_id,
          scope:,
          created_at: now,
          last_used_at: None,
          revoked_at: None,
        )
      let state =
        State(..state, oauth_grants: dict.insert(state.oauth_grants, id, g))
      #(
        add_event(
          state,
          now,
          user_actor(user_id),
          None,
          "oauth_grant",
          client_id,
        ),
        g,
      )
    }
  }
}

pub fn merge_scopes(a: String, b: String) -> String {
  list.append(string.split(a, " "), string.split(b, " "))
  |> list.filter(fn(s) { s != "" })
  |> list.unique
  |> list.sort(string.compare)
  |> string.join(" ")
}

pub fn put_token(state: State, token: OAuthToken) -> State {
  State(
    ..state,
    oauth_tokens: dict.insert(state.oauth_tokens, token.token_sha256, token),
  )
}

pub fn grant(state: State, id: Int) -> Option(OAuthGrant) {
  dict.get(state.oauth_grants, id) |> option.from_result
}

/// A valid (unexpired, unrevoked) token of the given kind, with its grant.
pub fn valid_token(
  state: State,
  token_sha256: String,
  kind: model.TokenKind,
  now: Int,
) -> Option(#(OAuthToken, OAuthGrant)) {
  case dict.get(state.oauth_tokens, token_sha256) {
    Ok(t) if t.kind == kind && t.expires_at > now ->
      case grant(state, t.grant) {
        Some(g) if g.revoked_at == None -> Some(#(t, g))
        _ -> None
      }
    _ -> None
  }
}

pub fn token(state: State, token_sha256: String) -> Option(OAuthToken) {
  dict.get(state.oauth_tokens, token_sha256) |> option.from_result
}

pub fn mark_token_used(state: State, token_sha256: String, now: Int) -> State {
  case dict.get(state.oauth_tokens, token_sha256) {
    Ok(t) -> put_token(state, OAuthToken(..t, used_at: Some(now)))
    Error(_) -> state
  }
}

/// Revoke every token in a refresh-token family (refresh-token reuse).
pub fn revoke_family(state: State, family: String) -> State {
  State(
    ..state,
    oauth_tokens: dict.filter(state.oauth_tokens, fn(_, t) {
      t.family != family
    }),
  )
}

pub fn delete_token(state: State, token_sha256: String) -> State {
  State(..state, oauth_tokens: dict.delete(state.oauth_tokens, token_sha256))
}

pub fn touch_grant(state: State, grant_id: Int, now: Int) -> State {
  case dict.get(state.oauth_grants, grant_id) {
    Ok(g) ->
      State(
        ..state,
        oauth_grants: dict.insert(
          state.oauth_grants,
          grant_id,
          OAuthGrant(..g, last_used_at: Some(now)),
        ),
      )
    Error(_) -> state
  }
}

pub fn revoke_grant(
  state: State,
  grant_id: Int,
  user_id: Int,
  now: Int,
) -> State {
  case dict.get(state.oauth_grants, grant_id) {
    Ok(g) if g.user == user_id ->
      State(
        ..state,
        oauth_grants: dict.insert(
          state.oauth_grants,
          grant_id,
          OAuthGrant(..g, revoked_at: Some(now)),
        ),
        oauth_tokens: dict.filter(state.oauth_tokens, fn(_, t) {
          t.grant != grant_id
        }),
      )
      |> add_event(
        now,
        user_actor(user_id),
        None,
        "oauth_grant_revoked",
        g.client_id,
      )
    _ -> state
  }
}

pub fn grants_of(state: State, user_id: Int) -> List(OAuthGrant) {
  dict.values(state.oauth_grants)
  |> list.filter(fn(g) { g.user == user_id && option.is_none(g.revoked_at) })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

// --- retention ------------------------------------------------------------------

pub type RetentionPolicy {
  RetentionPolicy(
    closed_items_days: Int,
    events_days: Int,
    judgment_detail_days: Int,
    judgments_days: Int,
  )
}

/// Prune old data, keeping referential integrity.
pub fn prune(state: State, policy: RetentionPolicy, now: Int) -> State {
  let item_cutoff = now - policy.closed_items_days * day_ms
  let doomed =
    dict.values(state.items)
    |> list.filter(fn(i) {
      case i.closed_at {
        Some(at) -> at < item_cutoff
        None -> False
      }
    })
    |> list.map(fn(i) { i.id })
  let is_doomed = fn(id: Option(Int)) {
    case id {
      Some(i) -> list.contains(doomed, i)
      None -> False
    }
  }
  let items =
    state.items
    |> dict.drop(doomed)
    |> dict.map_values(fn(_, i) {
      case is_doomed(i.overlaps) {
        True -> Item(..i, overlaps: None)
        False -> i
      }
    })
  let findings =
    dict.filter(state.findings, fn(_, f) {
      !is_doomed(f.item) && !is_doomed(f.related_item)
    })
  let events =
    list.filter(state.events, fn(e) {
      e.at >= now - policy.events_days * day_ms
    })
  let detail_cutoff = now - policy.judgment_detail_days * day_ms
  let judgments =
    state.judgments
    |> dict.filter(fn(_, j) { j.at >= now - policy.judgments_days * day_ms })
    |> dict.map_values(fn(_, j) {
      case j.at < detail_cutoff {
        True -> Judgment(..j, request: None, response: None)
        False -> j
      }
    })
  let week = 7 * day_ms
  let sessions =
    dict.filter(state.web_sessions, fn(_, s) { s.expires_at > now })
  let tokens = dict.filter(state.oauth_tokens, fn(_, t) { t.expires_at > now })
  let old_revoked = fn(at: Option(Int)) {
    case at {
      Some(t) -> t < now - week
      None -> False
    }
  }
  let grants =
    dict.filter(state.oauth_grants, fn(_, g) { !old_revoked(g.revoked_at) })
  let tokens = dict.filter(tokens, fn(_, t) { dict.has_key(grants, t.grant) })
  let links =
    dict.filter(state.mcp_links, fn(_, l) { !old_revoked(l.revoked_at) })
  State(
    ..state,
    items:,
    findings:,
    events:,
    judgments:,
    web_sessions: sessions,
    oauth_tokens: tokens,
    oauth_grants: grants,
    mcp_links: links,
  )
}

pub fn hours(n: Int) -> Int {
  n * hour_ms
}

pub fn days(n: Int) -> Int {
  n * day_ms
}

/// Resolve an agent's live findings of one kind that are not tied to an item
/// (e.g. `too_many_open` once the agent is back within the guideline).
pub fn resolve_agent_findings(
  state: State,
  agent_id: Int,
  kind: FindingKind,
  now: Int,
) -> State {
  dict.values(state.findings)
  |> list.filter(fn(f) {
    f.agent == agent_id && f.kind == kind && model.finding_is_live(f)
  })
  |> list.fold(state, fn(s, f) {
    put_finding(
      s,
      Finding(..f, status: model.FindingResolved, closed_at: Some(now)),
    )
  })
}
