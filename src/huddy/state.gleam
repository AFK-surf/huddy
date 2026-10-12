//// Pure operations on `State`. The store actor is the only caller; every
//// function here is deterministic given its inputs (time is passed in).

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import huddy/model.{
  type Agent, type Comment, type CommentAuthor, type DocFile, type DocRevision,
  type Document, type Finding, type FindingKind, type Item, type ItemState,
  type Kind, type McpLink, type OAuthGrant, type OAuthToken, type State,
  type User, Agent, Comment, Document, Event, Finding, Item, Judgment, McpLink,
  OAuthGrant, OAuthToken, State, User, WebSession,
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

pub fn get_agent(state: State, id: Int) -> Option(Agent) {
  dict.get(state.agents, id) |> option.from_result
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
    /// linked documents; must exist (see `check_docs`)
    docs: List(Int),
  )
}

/// Create an item. An agent may have several active goals.
pub fn create_item(
  state: State,
  agent_id: Int,
  new: NewItem,
  now: Int,
) -> #(State, Item) {
  let #(state, id) =
    bump(state, fn(n) { #(n.item, model.NextIds(..n, item: n.item + 1)) })
  // until the decision model classifies it, a task serves the agent's goal
  // when it has just one
  let goal = case new.kind {
    model.Task ->
      case
        open_items_of(state, agent_id)
        |> list.filter(fn(i) { i.kind == model.Goal })
      {
        [only] -> Some(only.id)
        _ -> None
      }
    _ -> None
  }
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
      goal:,
      seen_by: None,
      seen_at: None,
      hidden_by: None,
      hidden_note: None,
      docs: list.unique(new.docs),
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
    /// replaces the linked documents; must exist (see `check_docs`)
    docs: Option(List(Int)),
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
  let docs = option.map(edit.docs, list.unique) |> option.unwrap(item.docs)
  use _ <- result.try(check_docs(state, docs))
  let content_changed =
    title != item.title
    || detail != item.detail
    || blocking != item.blocking
    || options != item.options
    || docs != item.docs
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
          docs:,
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
      close_item(state, current, s, now, actor, "")
    }
    None -> state
  }
  let state = touch_agent(state, agent_id, now)
  let final = get_item(state, id) |> option.unwrap(item)
  Ok(#(state, EditOutcome(item: final, content_changed:)))
}

/// Close one of the agent's active goals as `replaced` (by a new goal).
pub fn replace_goal(
  state: State,
  agent_id: Int,
  goal_id: Int,
  now: Int,
) -> Result(State, String) {
  case get_item(state, goal_id) {
    Some(goal) if goal.agent != agent_id ->
      Error(
        model.item_ref(goal_id)
        <> " belongs to another agent; agents can only replace their own goals.",
      )
    Some(goal) if goal.kind == model.Goal && goal.state == model.Active ->
      Ok(close_item(state, goal, model.Replaced, now, agent_actor(agent_id), ""))
    Some(_) -> Error(model.item_ref(goal_id) <> " is not an active goal.")
    None -> Error("No item " <> model.item_ref(goal_id) <> ".")
  }
}

/// Close an item: set the final state, resolve its findings and any
/// duplicate/overlap findings that point at it. `note` is appended to the
/// event's detail.
fn close_item(
  state: State,
  item: Item,
  to: ItemState,
  now: Int,
  actor: String,
  note: String,
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
    model.state_to_string(to) <> note,
  )
}

// --- documents ----------------------------------------------------------------

pub fn get_document(state: State, id: Int) -> Option(Document) {
  dict.get(state.documents, id) |> option.from_result
}

/// All documents, most recently updated first.
pub fn documents(state: State) -> List(Document) {
  dict.values(state.documents)
  |> list.sort(fn(a, b) {
    case int.compare(b.updated_at, a.updated_at) {
      order.Eq -> int.compare(b.id, a.id)
      o -> o
    }
  })
}

/// Who uploaded a document: "alice/codex/huddy", plus who uploaded the
/// current version when that was another agent.
pub fn doc_byline(state: State, doc: Document) -> String {
  agent_label(state, doc.agent)
  <> case doc.updated_by == doc.agent {
    True -> ""
    False ->
      " (revision "
      <> int.to_string(doc.version)
      <> " by "
      <> agent_label(state, doc.updated_by)
      <> ")"
  }
}

/// The document, if it exists and is still at the given revision.
pub fn check_revision(
  state: State,
  at: DocRevision,
) -> Result(Document, String) {
  case get_document(state, at.id) {
    None -> Error(no_document(at.id))
    Some(doc) if doc.version == at.revision -> Ok(doc)
    Some(doc) ->
      Error(
        model.doc_ref(doc)
        <> " is at revision "
        <> int.to_string(doc.version)
        <> ", not "
        <> int.to_string(at.revision)
        <> ": it changed since you read it ("
        <> doc_byline(state, doc)
        <> "). Read it again, then retry with revision "
        <> int.to_string(doc.version)
        <> ".",
      )
  }
}

/// Every id must name an existing document.
pub fn check_docs(state: State, ids: List(Int)) -> Result(Nil, String) {
  case list.find(ids, fn(id) { !dict.has_key(state.documents, id) }) {
    Ok(id) -> Error(no_document(id) <> " List documents with huddy_doc_list.")
    Error(_) -> Ok(Nil)
  }
}

/// "No document 42.": the error for an id that names no document.
pub fn no_document(id: Int) -> String {
  "No document " <> int.to_string(id) <> "."
}

/// Items (open or closed) that link to a document, newest first.
pub fn items_with_doc(state: State, doc_id: Int) -> List(Item) {
  dict.values(state.items)
  |> list.filter(fn(i) { list.contains(i.docs, doc_id) })
  |> list.sort(fn(a, b) { int.compare(b.updated_at, a.updated_at) })
}

pub type NewDocument {
  NewDocument(
    title: String,
    /// for a new document (see `model.doc_slug`); a new version keeps the
    /// document's slug
    slug: String,
    files: List(DocFile),
    storage_key: String,
    /// replace this document, which must still be at this revision, instead
    /// of creating one
    replaces: Option(DocRevision),
  )
}

/// Store a new document, or a new version of any document (documents are
/// shared: any agent may replace one). Returns the document and, for a new version, the storage key of the
/// version it replaced (whose files the caller deletes).
pub fn put_document(
  state: State,
  agent_id: Int,
  new: NewDocument,
  now: Int,
) -> Result(#(State, Document, Option(String)), String) {
  let size = list.fold(new.files, 0, fn(n, f) { n + f.size })
  let actor = agent_actor(agent_id)
  case new.replaces {
    None -> {
      let #(state, id) =
        bump(state, fn(n) {
          #(n.document, model.NextIds(..n, document: n.document + 1))
        })
      let doc =
        Document(
          id:,
          slug: new.slug,
          agent: agent_id,
          updated_by: agent_id,
          title: new.title,
          files: new.files,
          size:,
          storage_key: new.storage_key,
          version: 1,
          created_at: now,
          updated_at: now,
          public: None,
        )
      let state =
        State(..state, documents: dict.insert(state.documents, id, doc))
        |> touch_agent(agent_id, now)
        |> add_event(now, actor, None, "doc_uploaded", doc_event(doc))
      Ok(#(state, doc, None))
    }
    Some(at) -> {
      let id = at.id
      use old <- result.try(check_revision(state, at))
      let doc =
        Document(
          ..old,
          updated_by: agent_id,
          title: new.title,
          files: new.files,
          size:,
          storage_key: new.storage_key,
          version: old.version + 1,
          updated_at: now,
        )
      let state =
        State(..state, documents: dict.insert(state.documents, id, doc))
        |> touch_agent(agent_id, now)
        |> add_event(now, actor, None, "doc_replaced", doc_event(doc))
      Ok(#(state, doc, Some(old.storage_key)))
    }
  }
}

fn doc_event(doc: Document) -> String {
  model.doc_ref(doc) <> " v" <> int.to_string(doc.version) <> ": " <> doc.title
}

/// Delete a document (any agent or human may); items that linked to it lose
/// the link. `actor` is `agent_actor(…)` or `user_actor(…)`.
pub fn delete_document(
  state: State,
  at: DocRevision,
  actor: String,
  now: Int,
) -> Result(#(State, Document), String) {
  let id = at.id
  use doc <- result.try(check_revision(state, at))
  let items =
    dict.map_values(state.items, fn(_, i) {
      case list.contains(i.docs, id) {
        True -> Item(..i, docs: list.filter(i.docs, fn(d) { d != id }))
        False -> i
      }
    })
  let state =
    State(..state, items:, documents: dict.delete(state.documents, id))
    |> add_event(
      now,
      actor,
      None,
      "doc_deleted",
      model.doc_ref(doc) <> ": " <> doc.title,
    )
  Ok(#(state, doc))
}

/// Who shares a document or stops sharing it: a human, or an agent (on
/// behalf of its owner).
pub type Sharer {
  ByUser(Int)
  ByAgent(Int)
}

fn sharer_actor(sharer: Sharer) -> String {
  case sharer {
    ByUser(id) -> user_actor(id)
    ByAgent(id) -> agent_actor(id)
  }
}

/// Share a document publicly (any human or agent may): anyone with its link
/// can read the current version, whoever uploads it. Sharing a document that
/// is already public keeps its link.
pub fn share_document(
  state: State,
  id: Int,
  sharer: Sharer,
  nonce: String,
  now: Int,
) -> Result(#(State, Document), String) {
  let by = case sharer {
    ByUser(user) -> Ok(#(user, None))
    ByAgent(agent) ->
      case get_agent(state, agent) {
        Some(a) -> Ok(#(a.owner, Some(agent)))
        None -> Error("No agent " <> int.to_string(agent) <> ".")
      }
  }
  case get_document(state, id), by {
    None, _ -> Error(no_document(id))
    _, Error(reason) -> Error(reason)
    Some(Document(public: Some(_), ..) as doc), _ -> Ok(#(state, doc))
    Some(doc), Ok(#(user, agent)) -> {
      let doc =
        Document(
          ..doc,
          public: Some(model.PublicLink(nonce:, by: user, agent:, at: now)),
        )
      let state =
        State(..state, documents: dict.insert(state.documents, id, doc))
        |> add_event(
          now,
          sharer_actor(sharer),
          None,
          "doc_shared",
          model.doc_ref(doc) <> ": " <> doc.title,
        )
      Ok(#(state, doc))
    }
  }
}

/// Stop sharing a document: its public link stops working for good (sharing
/// it again makes a new link).
pub fn unshare_document(
  state: State,
  id: Int,
  sharer: Sharer,
  now: Int,
) -> Result(#(State, Document), String) {
  case get_document(state, id) {
    None -> Error(no_document(id))
    Some(Document(public: None, ..) as doc) -> Ok(#(state, doc))
    Some(doc) -> {
      let doc = Document(..doc, public: None)
      let state =
        State(..state, documents: dict.insert(state.documents, id, doc))
        |> add_event(
          now,
          sharer_actor(sharer),
          None,
          "doc_unshared",
          model.doc_ref(doc) <> ": " <> doc.title,
        )
      Ok(#(state, doc))
    }
  }
}

/// Who shared a document publicly: "alice/codex/huddy" for an agent, else
/// the human's handle.
pub fn shared_by(state: State, link: model.PublicLink) -> String {
  case link.agent {
    Some(agent) -> agent_label(state, agent)
    None -> handle_of(state, link.by)
  }
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

/// File a task under one of its agent's goals (or under none). Changes no
/// version: this is Huddy's classification, not the agent's content. A
/// task only ever goes under its own agent's goal; anything else is
/// ignored.
pub fn set_task_goal(state: State, task_id: Int, goal: Option(Int)) -> State {
  case get_item(state, task_id) {
    Some(i) if i.kind == model.Task && i.goal != goal ->
      case goal == None || is_goal_of(state, goal, i.agent) {
        True -> put_item(state, Item(..i, goal:))
        False -> state
      }
    _ -> state
  }
}

/// Move the open tasks filed under goal `from` to goal `to` (a goal that
/// replaces another takes over its tasks), when `to` is their agent's goal.
pub fn move_tasks(state: State, from: Int, to: Int) -> State {
  open_items(state)
  |> list.filter(fn(i) { i.kind == model.Task && i.goal == Some(from) })
  |> list.fold(state, fn(s, i) { set_task_goal(s, i.id, Some(to)) })
}

fn is_goal_of(state: State, goal: Option(Int), agent_id: Int) -> Bool {
  case option.then(goal, get_item(state, _)) {
    Some(g) -> g.kind == model.Goal && g.agent == agent_id
    None -> False
  }
}

/// The agent's open tasks not filed under one of its open goals.
pub fn unfiled_tasks(state: State, agent_id: Int) -> List(Item) {
  let open = open_items_of(state, agent_id)
  let goals =
    list.filter_map(open, fn(i) {
      case i.kind {
        model.Goal -> Ok(i.id)
        _ -> Error(Nil)
      }
    })
  list.filter(open, fn(i) {
    i.kind == model.Task
    && case i.goal {
      Some(g) -> !list.contains(goals, g)
      None -> True
    }
  })
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
          acked_at: None,
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
      put_item(state, Item(..i, stale_p:, overlaps:))
    }
  }
}

pub fn live_findings_for_agent(state: State, agent_id: Int) -> List(Finding) {
  dict.values(state.findings)
  |> list.filter(fn(f) { f.agent == agent_id && model.finding_is_live(f) })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
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
                  acked_at: option.or(f.acked_at, Some(now)),
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

// --- comments -----------------------------------------------------------------

pub type CommentLimits {
  CommentLimits(max_chars: Int, per_item: Int)
}

fn put_comment(state: State, c: Comment) -> State {
  State(..state, comments: dict.insert(state.comments, c.id, c))
}

pub fn get_comment(state: State, id: Int) -> Option(Comment) {
  dict.get(state.comments, id) |> option.from_result
}

/// An item's comments, oldest first.
pub fn comments_for_item(state: State, item_id: Int) -> List(Comment) {
  dict.values(state.comments)
  |> list.filter(fn(c) { c.item == item_id })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

pub fn is_human(c: Comment) -> Bool {
  case c.author {
    model.HumanAuthor(_) -> True
    model.AgentAuthor(_) -> False
  }
}

/// Add a comment to an open item: a human's (any item; on a decision it may
/// pick one of the options, and it marks the decision seen), or the item's
/// own agent replying in the thread.
pub fn add_comment(
  state: State,
  item_id: Int,
  author: CommentAuthor,
  body: String,
  pick: Option(String),
  limits: CommentLimits,
  now: Int,
) -> Result(#(State, Comment), String) {
  let ref = model.item_ref(item_id)
  use item <- result.try(
    get_item(state, item_id) |> option.to_result("No item " <> ref <> "."),
  )
  use _ <- result.try(case model.is_open(item) {
    True -> Ok(Nil)
    False -> Error(ref <> " is closed; you can only comment on open items.")
  })
  use _ <- result.try(case author {
    model.AgentAuthor(a) if a != item.agent ->
      Error(
        ref
        <> " belongs to "
        <> agent_label(state, item.agent)
        <> "; agents can only comment on their own items.",
      )
    _ -> Ok(Nil)
  })
  let body = string.trim(body)
  let pick = case pick {
    Some(p) ->
      case string.trim(p) {
        "" -> None
        _ -> Some(p)
      }
    None -> None
  }
  use _ <- result.try(case pick, author {
    None, _ -> Ok(Nil)
    Some(_), model.AgentAuthor(_) -> Error("Only humans pick an option.")
    Some(p), _ ->
      case item.kind == model.Decision && list.contains(item.options, p) {
        True -> Ok(Nil)
        False ->
          Error("The options of " <> ref <> " changed; reload and pick again.")
      }
  })
  use _ <- result.try(case body, pick {
    "", None -> Error("Write a comment.")
    _, _ ->
      case string.length(body) > limits.max_chars {
        True ->
          Error(
            "Comments are at most "
            <> int.to_string(limits.max_chars)
            <> " characters.",
          )
        False -> Ok(Nil)
      }
  })
  use _ <- result.try(
    case list.length(comments_for_item(state, item_id)) >= limits.per_item {
      True -> Error(ref <> " has too many comments; start a new item.")
      False -> Ok(Nil)
    },
  )
  let #(state, id) =
    bump(state, fn(n) {
      #(n.comment, model.NextIds(..n, comment: n.comment + 1))
    })
  let comment =
    Comment(
      id:,
      item: item_id,
      author:,
      body:,
      pick:,
      created_at: now,
      sent_at: None,
      acked_at: None,
    )
  let #(actor, state) = case author {
    model.HumanAuthor(user) -> {
      // answering a decision counts as seeing it
      let state = case item.kind, item.seen_by {
        model.Decision, None ->
          put_item(state, Item(..item, seen_by: Some(user), seen_at: Some(now)))
        _, _ -> state
      }
      #(user_actor(user), state)
    }
    model.AgentAuthor(agent) -> #(
      agent_actor(agent),
      touch_agent(state, agent, now),
    )
  }
  let detail =
    case pick {
      Some(p) ->
        "picked "
        <> p
        <> case body {
          "" -> ""
          _ -> ": "
        }
      None -> ""
    }
    <> string.slice(body, 0, 80)
  let state =
    put_comment(state, comment)
    |> add_event(now, actor, Some(item_id), "comment_added", detail)
  Ok(#(state, comment))
}

/// What the agent hasn't acknowledged yet, oldest first: human comments on
/// its items (whatever state the items are in now) and its live findings.
pub fn unacked(state: State, agent_id: Int) -> #(List(Comment), List(Finding)) {
  let comments =
    dict.values(state.comments)
    |> list.filter(fn(c) {
      is_human(c)
      && option.is_none(c.acked_at)
      && case get_item(state, c.item) {
        Some(i) -> i.agent == agent_id
        None -> False
      }
    })
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
  let findings =
    dict.values(state.findings)
    |> list.filter(fn(f) {
      f.agent == agent_id
      && model.finding_is_live(f)
      && option.is_none(f.acked_at)
    })
    |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
  #(comments, findings)
}

/// Record that these comments and findings went out in a tool result.
/// Sending is not acknowledging: they keep going out until acked.
pub fn mark_sent(
  state: State,
  comment_ids: List(Int),
  finding_ids: List(Int),
  now: Int,
) -> State {
  let state =
    list.fold(comment_ids, state, fn(s, id) {
      case dict.get(s.comments, id) {
        Ok(c) -> put_comment(s, Comment(..c, sent_at: Some(now)))
        Error(_) -> s
      }
    })
  list.fold(finding_ids, state, fn(s, id) {
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

/// What `huddy_ack` names: a comment or a finding.
pub type AckRef {
  AckComment(Int)
  AckFinding(Int)
}

/// Parse "c7" or "f88". Bare numbers are refused: they could be either.
pub fn parse_ack_ref(text: String) -> Result(AckRef, String) {
  let text = string.trim(text)
  let parsed = case text {
    "c" <> n -> int.parse(n) |> result.map(AckComment)
    "f" <> n -> int.parse(n) |> result.map(AckFinding)
    _ -> Error(Nil)
  }
  result.replace_error(
    parsed,
    "Unknown id " <> text <> ": use the ids as shown, like c7 or f88.",
  )
}

/// Acknowledge comments and findings addressed to this agent. Acking one
/// that is already acked (or a finding that is dismissed or resolved) is
/// fine, so a retry is safe. All or nothing: one bad id refuses the call.
pub fn ack(
  state: State,
  agent_id: Int,
  refs: List(AckRef),
  now: Int,
) -> Result(State, String) {
  list.try_fold(refs, state, fn(s, r) {
    case r {
      AckComment(id) -> {
        let ref = model.comment_ref(id)
        case get_comment(s, id) {
          None -> Error("No comment " <> ref <> ".")
          Some(c) -> {
            let owner = case get_item(s, c.item) {
              Some(i) -> Some(i.agent)
              None -> None
            }
            case is_human(c) && owner == Some(agent_id) {
              False -> Error(ref <> " is not addressed to you.")
              True ->
                case c.acked_at {
                  Some(_) -> Ok(s)
                  None ->
                    put_comment(s, Comment(..c, acked_at: Some(now)))
                    |> add_event(
                      now,
                      agent_actor(agent_id),
                      Some(c.item),
                      "comment_acked",
                      ref,
                    )
                    |> Ok
                }
            }
          }
        }
      }
      AckFinding(id) -> {
        let ref = model.finding_ref(id)
        case dict.get(s.findings, id) {
          Error(_) -> Error("No finding " <> ref <> ".")
          Ok(f) if f.agent != agent_id ->
            Error(ref <> " is addressed to another agent.")
          Ok(f) ->
            case f.acked_at {
              Some(_) -> Ok(s)
              None -> Ok(put_finding(s, Finding(..f, acked_at: Some(now))))
            }
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
      last_used_ip: None,
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

/// Record a use of a link: when, and from which client address.
pub fn touch_link(state: State, link_id: Int, now: Int, ip: String) -> State {
  case dict.get(state.mcp_links, link_id) {
    Ok(l) ->
      State(
        ..state,
        mcp_links: dict.insert(
          state.mcp_links,
          link_id,
          McpLink(..l, last_used_at: Some(now), last_used_ip: Some(ip)),
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
          last_used_ip: None,
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

/// Record a use of a grant: when, and from which client address.
pub fn touch_grant(state: State, grant_id: Int, now: Int, ip: String) -> State {
  case dict.get(state.oauth_grants, grant_id) {
    Ok(g) ->
      State(
        ..state,
        oauth_grants: dict.insert(
          state.oauth_grants,
          grant_id,
          OAuthGrant(..g, last_used_at: Some(now), last_used_ip: Some(ip)),
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
    /// 0 keeps inactive agents' items open
    inactive_agent_days: Int,
  )
}

/// Close the open items of agents not seen for `days` (0: never), as given
/// up: goals abandoned, tasks dropped, decisions withdrawn. They then age out
/// like any other closed item.
pub fn close_inactive(state: State, days: Int, now: Int) -> State {
  case days > 0 {
    False -> state
    True -> {
      let cutoff = now - days * day_ms
      let inactive = fn(agent_id) {
        case get_agent(state, agent_id) {
          Some(a) -> a.last_seen_at < cutoff
          None -> True
        }
      }
      let note = " (agent inactive for " <> int.to_string(days) <> " days)"
      open_items(state)
      |> list.filter(fn(i) { inactive(i.agent) })
      |> list.map(fn(i) { i.id })
      |> list.fold(state, fn(s, id) {
        // re-read: closing one item can update another's flags
        case get_item(s, id) {
          Some(i) ->
            close_item(s, i, model.given_up_state(i.kind), now, "janitor", note)
          None -> s
        }
      })
    }
  }
}

/// Close inactive agents' items, then prune old data, keeping referential
/// integrity.
pub fn prune(state: State, policy: RetentionPolicy, now: Int) -> State {
  let state = close_inactive(state, policy.inactive_agent_days, now)
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
      let i = case is_doomed(i.overlaps) {
        True -> Item(..i, overlaps: None)
        False -> i
      }
      case is_doomed(i.goal) {
        True -> Item(..i, goal: None)
        False -> i
      }
    })
  let findings =
    dict.filter(state.findings, fn(_, f) {
      !is_doomed(f.item) && !is_doomed(f.related_item)
    })
  let comments =
    dict.filter(state.comments, fn(_, c) { !list.contains(doomed, c.item) })
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
    comments:,
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
