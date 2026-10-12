//// Domain types. Everything durable lives in `State`, persisted as one JSON
//// file by `huddy/persist`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
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
    /// tasks: the agent's goal this task serves, as classified by the
    /// decision model (see `huddy/review`); None when it serves none, or
    /// before it is classified
    goal: Option(Int),
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
/// read, replace and delete every document. Each version is one zip in
/// `storage.documents_dir`, named by `storage_key` (see `huddy/documents`);
/// the state file holds the metadata.
pub type Document {
  Document(
    id: Int,
    /// set when the document is created, never changed: its ref is
    /// "<id>-<slug>" (see `doc_ref`); may be empty
    slug: String,
    /// the agent that uploaded the first version
    agent: Int,
    /// the agent that uploaded the current version (any agent can)
    updated_by: Int,
    title: String,
    /// sorted by path; always includes "index.md"
    files: List(DocFile),
    /// total size of the files in bytes
    size: Int,
    /// names this version's zip in `storage.documents_dir`
    storage_key: String,
    version: Int,
    created_at: Int,
    updated_at: Int,
    /// shared publicly: anyone with the link can read the current version
    public: Option(PublicLink),
  )
}

/// A document's public link. The link's token is derived from `nonce` and
/// the server's secret key (see `documents.public_token`), so the state file
/// alone does not reveal it, and rotating the key revokes every link.
pub type PublicLink {
  PublicLink(
    nonce: String,
    /// the user who shared it, or whose agent did; the link works while
    /// they are on the allowlist
    by: Int,
    /// the agent that shared it, if an agent did
    agent: Option(Int),
    at: Int,
  )
}

pub type DocFile {
  /// `path` in the document, unzipped `size`, and its name in the stored zip
  /// (which can differ: "./", a top-level folder)
  DocFile(path: String, size: Int, entry: String)
}

/// A document at a given revision (its `version`). Replacing or deleting a
/// document names the revision the caller last saw; if the document has
/// changed since, the change is refused.
pub type DocRevision {
  DocRevision(id: Int, revision: Int)
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
    /// first included in a tool result for the agent
    delivered_at: Option(Int),
    /// the agent acknowledged it (`huddy_ack`, or a dismissal); it is then
    /// no longer repeated in tool results, but stays live
    acked_at: Option(Int),
    closed_at: Option(Int),
  )
}

pub type CommentAuthor {
  HumanAuthor(user: Int)
  /// the item's own agent, replying in its thread
  AgentAuthor(agent: Int)
}

/// A comment on an item: a human's answer or request, or the item's agent
/// replying. A human comment is repeated in the agent's tool results until
/// the agent acknowledges it.
pub type Comment {
  Comment(
    id: Int,
    item: Int,
    author: CommentAuthor,
    body: String,
    /// decisions: the option the human picked
    pick: Option(String),
    created_at: Int,
    /// human comments: last included in a tool result for the agent
    sent_at: Option(Int),
    /// human comments: the agent acknowledged it
    acked_at: Option(Int),
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
    last_used_ip: Option(String),
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
    last_used_ip: Option(String),
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
    comment: Int,
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
    comments: Dict(Int, Comment),
  )
}

pub fn empty_state() -> State {
  State(
    saved_at: 0,
    next_id: NextIds(1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
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
    comments: dict.new(),
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

/// The closing state for an item given up rather than finished.
pub fn given_up_state(kind: Kind) -> ItemState {
  case kind {
    Goal -> Abandoned
    Task -> Dropped
    Decision -> Withdrawn
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

pub fn comment_ref(id: Int) -> String {
  "c" <> int.to_string(id)
}

/// A document as agents and URLs name it: "12-design-notes", or "12" when
/// it has no slug.
pub fn doc_ref(doc: Document) -> String {
  case doc.slug {
    "" -> int.to_string(doc.id)
    slug -> int.to_string(doc.id) <> "-" <> slug
  }
}

/// Parse a document ref ("12-design-notes", or just "12") into its id. The
/// id alone names the document; the slug is not checked.
pub fn parse_doc_ref(text: String) -> Result(Int, Nil) {
  let text = string.trim(text)
  case string.split_once(text, "-") {
    Ok(#(id, _)) -> int.parse(id)
    Error(_) -> int.parse(text)
  }
  |> result.try(fn(id) {
    case id > 0 {
      True -> Ok(id)
      False -> Error(Nil)
    }
  })
}

pub const doc_slug_max = 60

/// A document slug: lowercase ASCII letters and digits, everything else
/// collapsed to single "-", at most `doc_slug_max` characters. Empty when
/// the text has no letters or digits.
pub fn doc_slug(text: String) -> String {
  text
  |> string.lowercase
  |> string.to_graphemes
  |> list.map(fn(c) {
    case string.to_utf_codepoints(c) {
      [cp] -> {
        let n = string.utf_codepoint_to_int(cp)
        case { n >= 97 && n <= 122 } || { n >= 48 && n <= 57 } {
          True -> c
          False -> "-"
        }
      }
      _ -> "-"
    }
  })
  |> string.concat
  |> string.split("-")
  |> list.filter(fn(part) { part != "" })
  |> string.join("-")
  |> string.slice(0, doc_slug_max)
  |> trim_trailing_dash
}

fn trim_trailing_dash(s: String) -> String {
  case string.ends_with(s, "-") {
    True -> trim_trailing_dash(string.drop_end(s, 1))
    False -> s
  }
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
