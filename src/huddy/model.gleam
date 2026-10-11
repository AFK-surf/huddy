//// Domain types. Everything durable lives in `State`, persisted as one JSON
//// file by `huddy/persist`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type User {
  User(
    id: Int,
    email: String,
    handle: String,
    notify_browser_non_blocking: Bool,
    created_at: Int,
    last_login_at: Option(Int),
  )
}

pub type WebSession {
  WebSession(
    token_sha256: String,
    user: Int,
    created_at: Int,
    expires_at: Int,
    user_agent: String,
  )
}

pub type Agent {
  Agent(
    id: Int,
    owner: Int,
    name: String,
    project: String,
    created_at: Int,
    last_seen_at: Int,
  )
}

pub type Kind {
  Goal
  Task
  Decision
}

pub type ItemState {
  Active
  Achieved
  Abandoned
  Replaced
  Done
  Dropped
  Open
  Resolved
  Withdrawn
}

pub type Item {
  Item(
    id: Int,
    agent: Int,
    kind: Kind,
    title: String,
    detail: String,
    blocking: Bool,
    options: List(String),
    state: ItemState,
    importance: Option(Float),
    reviewed_at: Option(Int),
    stale_p: Option(Float),
    overlaps: Option(Int),
    seen_by: Option(Int),
    seen_at: Option(Int),
    hidden_by: Option(Int),
    hidden_note: Option(String),
    /// documents the agent linked to this item
    docs: List(Int),
    version: Int,
    created_at: Int,
    updated_at: Int,
    closed_at: Option(Int),
  )
}

/// A Markdown document: an `index.md`, optionally with images and other
/// files it links to. Documents are global: every agent and every human can
/// read, replace and delete every document. The files live in `storage.documents_dir` under
/// `storage_key` (see `huddy/documents`); the state file holds the metadata.
pub type Document {
  Document(
    id: Int,
    /// the agent that uploaded the first version
    agent: Int,
    /// the agent that uploaded the current version (any agent can)
    updated_by: Int,
    title: String,
    /// sorted by path; always includes "index.md"
    files: List(DocFile),
    /// total size of the files in bytes
    size: Int,
    /// the directory below `storage.documents_dir` holding this version
    storage_key: String,
    version: Int,
    created_at: Int,
    updated_at: Int,
  )
}

pub type DocFile {
  DocFile(path: String, size: Int)
}

pub type FindingKind {
  Unclear
  NotAQuestion
  Duplicate
  Overlap
  Stale
  Untouched
  TooManyOpen
  Hidden
}

pub type FindingStatus {
  FindingOpen
  Delivered
  Dismissed
  FindingResolved
}

pub type Finding {
  Finding(
    id: Int,
    agent: Int,
    item: Option(Int),
    item_version: Option(Int),
    related_item: Option(Int),
    kind: FindingKind,
    confidence: Option(Float),
    message: String,
    judgment: Option(Int),
    status: FindingStatus,
    dismiss_reason: Option(String),
    created_at: Int,
    delivered_at: Option(Int),
    closed_at: Option(Int),
  )
}

pub type Event {
  Event(
    id: Int,
    at: Int,
    actor: String,
    item: Option(Int),
    event_type: String,
    /// Short human-readable detail, e.g. the new title or state.
    detail: String,
  )
}

pub type Judgment {
  Judgment(
    id: Int,
    at: Int,
    purpose: String,
    item: Option(Int),
    /// Full request/response; dropped after `judgment_detail_days`.
    request: Option(String),
    response: Option(String),
    latency_ms: Int,
    input_tokens: Int,
    output_tokens: Int,
    error: Option(String),
  )
}

pub type McpLink {
  McpLink(
    id: Int,
    user: Int,
    secret_sha256: String,
    label: String,
    pinned_name: Option(String),
    pinned_project: Option(String),
    scope: String,
    created_at: Int,
    last_used_at: Option(Int),
    revoked_at: Option(Int),
  )
}

pub type ClientKind {
  Cimd
  Dcr
}

pub type OAuthClient {
  OAuthClient(
    client_id: String,
    kind: ClientKind,
    client_name: String,
    redirect_uris: List(String),
    metadata: String,
    fetched_at: Option(Int),
    cache_until: Option(Int),
    created_at: Int,
  )
}

pub type OAuthGrant {
  OAuthGrant(
    id: Int,
    client_id: String,
    user: Int,
    scope: String,
    created_at: Int,
    last_used_at: Option(Int),
    revoked_at: Option(Int),
  )
}

pub type TokenKind {
  AccessToken
  RefreshToken
}

pub type OAuthToken {
  OAuthToken(
    token_sha256: String,
    grant: Int,
    kind: TokenKind,
    family: String,
    resource: String,
    expires_at: Int,
    used_at: Option(Int),
  )
}

pub type NextIds {
  NextIds(
    user: Int,
    agent: Int,
    item: Int,
    finding: Int,
    event: Int,
    judgment: Int,
    link: Int,
    grant: Int,
    document: Int,
  )
}

pub type State {
  State(
    saved_at: Int,
    next_id: NextIds,
    users: Dict(Int, User),
    web_sessions: Dict(String, WebSession),
    agents: Dict(Int, Agent),
    items: Dict(Int, Item),
    findings: Dict(Int, Finding),
    /// Newest first in memory; oldest first on disk.
    events: List(Event),
    judgments: Dict(Int, Judgment),
    mcp_links: Dict(Int, McpLink),
    oauth_clients: Dict(String, OAuthClient),
    oauth_grants: Dict(Int, OAuthGrant),
    oauth_tokens: Dict(String, OAuthToken),
    documents: Dict(Int, Document),
  )
}

pub fn empty_state() -> State {
  State(
    saved_at: 0,
    next_id: NextIds(1, 1, 1, 1, 1, 1, 1, 1, 1),
    users: dict.new(),
    web_sessions: dict.new(),
    agents: dict.new(),
    items: dict.new(),
    findings: dict.new(),
    events: [],
    judgments: dict.new(),
    mcp_links: dict.new(),
    oauth_clients: dict.new(),
    oauth_grants: dict.new(),
    oauth_tokens: dict.new(),
    documents: dict.new(),
  )
}

// --- string forms ------------------------------------------------------------

pub fn kind_to_string(kind: Kind) -> String {
  case kind {
    Goal -> "goal"
    Task -> "task"
    Decision -> "decision"
  }
}

pub fn kind_from_string(s: String) -> Result(Kind, Nil) {
  case s {
    "goal" -> Ok(Goal)
    "task" -> Ok(Task)
    "decision" -> Ok(Decision)
    _ -> Error(Nil)
  }
}

pub fn state_to_string(state: ItemState) -> String {
  case state {
    Active -> "active"
    Achieved -> "achieved"
    Abandoned -> "abandoned"
    Replaced -> "replaced"
    Done -> "done"
    Dropped -> "dropped"
    Open -> "open"
    Resolved -> "resolved"
    Withdrawn -> "withdrawn"
  }
}

pub fn state_from_string(s: String) -> Result(ItemState, Nil) {
  case s {
    "active" -> Ok(Active)
    "achieved" -> Ok(Achieved)
    "abandoned" -> Ok(Abandoned)
    "replaced" -> Ok(Replaced)
    "done" -> Ok(Done)
    "dropped" -> Ok(Dropped)
    "open" -> Ok(Open)
    "resolved" -> Ok(Resolved)
    "withdrawn" -> Ok(Withdrawn)
    _ -> Error(Nil)
  }
}

pub fn initial_state(kind: Kind) -> ItemState {
  case kind {
    Decision -> Open
    _ -> Active
  }
}

/// The states an agent may move an open item of this kind into.
pub fn closing_states(kind: Kind) -> List(ItemState) {
  case kind {
    Goal -> [Achieved, Abandoned]
    Task -> [Done, Dropped]
    Decision -> [Resolved, Withdrawn]
  }
}

pub fn is_open(item: Item) -> Bool {
  option.is_none(item.closed_at)
}

pub fn finding_kind_to_string(kind: FindingKind) -> String {
  case kind {
    Unclear -> "unclear"
    NotAQuestion -> "not_a_question"
    Duplicate -> "duplicate"
    Overlap -> "overlap"
    Stale -> "stale"
    Untouched -> "untouched"
    TooManyOpen -> "too_many_open"
    Hidden -> "hidden"
  }
}

pub fn finding_kind_from_string(s: String) -> Result(FindingKind, Nil) {
  list.find(
    [
      Unclear,
      NotAQuestion,
      Duplicate,
      Overlap,
      Stale,
      Untouched,
      TooManyOpen,
      Hidden,
    ],
    fn(k) { finding_kind_to_string(k) == s },
  )
}

pub fn finding_status_to_string(status: FindingStatus) -> String {
  case status {
    FindingOpen -> "open"
    Delivered -> "delivered"
    Dismissed -> "dismissed"
    FindingResolved -> "resolved"
  }
}

pub fn finding_status_from_string(s: String) -> Result(FindingStatus, Nil) {
  case s {
    "open" -> Ok(FindingOpen)
    "delivered" -> Ok(Delivered)
    "dismissed" -> Ok(Dismissed)
    "resolved" -> Ok(FindingResolved)
    _ -> Error(Nil)
  }
}

/// Findings that are still "live": not dismissed and not resolved.
pub fn finding_is_live(f: Finding) -> Bool {
  f.status == FindingOpen || f.status == Delivered
}

// --- ids as agents see them ---------------------------------------------------

pub fn item_ref(id: Int) -> String {
  "i" <> int.to_string(id)
}

pub fn finding_ref(id: Int) -> String {
  "f" <> int.to_string(id)
}

pub fn doc_ref(id: Int) -> String {
  "doc" <> int.to_string(id)
}

/// Parse "i41", "41", "f88" (with the given prefix) into an integer id.
pub fn parse_ref(text: String, prefix: String) -> Result(Int, Nil) {
  let text = string.trim(text)
  let text = case string.starts_with(text, prefix) {
    True -> string.drop_start(text, string.length(prefix))
    False -> text
  }
  int.parse(text)
}

pub fn agent_label(owner_handle: String, agent: Agent) -> String {
  owner_handle <> "/" <> agent.name <> "/" <> agent.project
}
