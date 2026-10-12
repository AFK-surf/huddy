//// JSON encoding/decoding of `State` for the storage file (format 1).
//// Fields added since format 1 was introduced (`documents`, item `docs`,
//// `comments`, finding `acked_at`) are optional when decoding, so older
//// files load unchanged.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import huddy/model.{
  type Agent, type Comment, type Document, type Event, type Finding, type Item,
  type Judgment, type McpLink, type NextIds, type OAuthClient, type OAuthGrant,
  type OAuthToken, type State, type User, type WebSession, Agent, Comment,
  DocFile, Document, Event, Finding, Item, Judgment, McpLink, NextIds,
  OAuthClient, OAuthGrant, OAuthToken, PublicLink, State, User, WebSession,
}

pub const format = 1

// --- encoding ----------------------------------------------------------------

fn opt(value: Option(a), encode: fn(a) -> Json) -> Json {
  json.nullable(value, encode)
}

pub fn encode_state(state: State, saved_at: Int) -> Json {
  json.object([
    #("format", json.int(format)),
    #("saved_at", json.int(saved_at)),
    #("next_id", encode_next_ids(state.next_id)),
    #(
      "users",
      json.array(
        dict.values(state.users) |> sort_by(fn(u) { u.id }),
        encode_user,
      ),
    ),
    #(
      "web_sessions",
      json.array(dict.values(state.web_sessions), encode_session),
    ),
    #(
      "agents",
      json.array(
        dict.values(state.agents) |> sort_by(fn(a) { a.id }),
        encode_agent,
      ),
    ),
    #(
      "items",
      json.array(
        dict.values(state.items) |> sort_by(fn(i) { i.id }),
        encode_item,
      ),
    ),
    #(
      "findings",
      json.array(
        dict.values(state.findings) |> sort_by(fn(f) { f.id }),
        encode_finding,
      ),
    ),
    #("events", json.array(list.reverse(state.events), encode_event)),
    #(
      "judgments",
      json.array(
        dict.values(state.judgments) |> sort_by(fn(j) { j.id }),
        encode_judgment,
      ),
    ),
    #(
      "mcp_links",
      json.array(
        dict.values(state.mcp_links) |> sort_by(fn(l) { l.id }),
        encode_link,
      ),
    ),
    #(
      "oauth",
      json.object([
        #(
          "clients",
          json.array(dict.values(state.oauth_clients), encode_client),
        ),
        #(
          "grants",
          json.array(
            dict.values(state.oauth_grants) |> sort_by(fn(g) { g.id }),
            encode_grant,
          ),
        ),
        #("tokens", json.array(dict.values(state.oauth_tokens), encode_token)),
      ]),
    ),
    #(
      "documents",
      json.array(
        dict.values(state.documents) |> sort_by(fn(d) { d.id }),
        encode_document,
      ),
    ),
    #(
      "comments",
      json.array(
        dict.values(state.comments) |> sort_by(fn(c) { c.id }),
        encode_comment,
      ),
    ),
  ])
}

fn sort_by(items: List(a), key: fn(a) -> Int) -> List(a) {
  list.sort(items, fn(a, b) { int.compare(key(a), key(b)) })
}

fn encode_next_ids(n: NextIds) -> Json {
  json.object([
    #("user", json.int(n.user)),
    #("agent", json.int(n.agent)),
    #("item", json.int(n.item)),
    #("finding", json.int(n.finding)),
    #("event", json.int(n.event)),
    #("judgment", json.int(n.judgment)),
    #("link", json.int(n.link)),
    #("grant", json.int(n.grant)),
    #("document", json.int(n.document)),
    #("comment", json.int(n.comment)),
  ])
}

fn encode_user(u: User) -> Json {
  json.object([
    #("id", json.int(u.id)),
    #("email", json.string(u.email)),
    #("handle", json.string(u.handle)),
    #("notify_browser_non_blocking", json.bool(u.notify_browser_non_blocking)),
    #("created_at", json.int(u.created_at)),
    #("last_login_at", opt(u.last_login_at, json.int)),
  ])
}

fn encode_session(s: WebSession) -> Json {
  json.object([
    #("token_sha256", json.string(s.token_sha256)),
    #("user", json.int(s.user)),
    #("created_at", json.int(s.created_at)),
    #("expires_at", json.int(s.expires_at)),
    #("user_agent", json.string(s.user_agent)),
  ])
}

fn encode_agent(a: Agent) -> Json {
  json.object([
    #("id", json.int(a.id)),
    #("owner", json.int(a.owner)),
    #("name", json.string(a.name)),
    #("project", json.string(a.project)),
    #("created_at", json.int(a.created_at)),
    #("last_seen_at", json.int(a.last_seen_at)),
  ])
}

pub fn encode_item(i: Item) -> Json {
  json.object([
    #("id", json.int(i.id)),
    #("agent", json.int(i.agent)),
    #("kind", json.string(model.kind_to_string(i.kind))),
    #("title", json.string(i.title)),
    #("detail", json.string(i.detail)),
    #("blocking", json.bool(i.blocking)),
    #("options", json.array(i.options, json.string)),
    #("state", json.string(model.state_to_string(i.state))),
    #("importance", opt(i.importance, json.float)),
    #("reviewed_at", opt(i.reviewed_at, json.int)),
    #("stale_p", opt(i.stale_p, json.float)),
    #("overlaps", opt(i.overlaps, json.int)),
    #("seen_by", opt(i.seen_by, json.int)),
    #("seen_at", opt(i.seen_at, json.int)),
    #("hidden_by", opt(i.hidden_by, json.int)),
    #("hidden_note", opt(i.hidden_note, json.string)),
    #("docs", json.array(i.docs, json.int)),
    #("version", json.int(i.version)),
    #("created_at", json.int(i.created_at)),
    #("updated_at", json.int(i.updated_at)),
    #("closed_at", opt(i.closed_at, json.int)),
  ])
}

pub fn encode_document(d: Document) -> Json {
  json.object([
    #("id", json.int(d.id)),
    #("slug", json.string(d.slug)),
    #("agent", json.int(d.agent)),
    #("updated_by", json.int(d.updated_by)),
    #("title", json.string(d.title)),
    #(
      "files",
      json.array(d.files, fn(f) {
        json.object([
          #("path", json.string(f.path)),
          #("size", json.int(f.size)),
          #("entry", json.string(f.entry)),
        ])
      }),
    ),
    #("size", json.int(d.size)),
    #("storage_key", json.string(d.storage_key)),
    #("version", json.int(d.version)),
    #("created_at", json.int(d.created_at)),
    #("updated_at", json.int(d.updated_at)),
    #(
      "public",
      opt(d.public, fn(p) {
        json.object([
          #("nonce", json.string(p.nonce)),
          #("by", json.int(p.by)),
          #("agent", opt(p.agent, json.int)),
          #("at", json.int(p.at)),
        ])
      }),
    ),
  ])
}

pub fn encode_finding(f: Finding) -> Json {
  json.object([
    #("id", json.int(f.id)),
    #("agent", json.int(f.agent)),
    #("item", opt(f.item, json.int)),
    #("item_version", opt(f.item_version, json.int)),
    #("related_item", opt(f.related_item, json.int)),
    #("kind", json.string(model.finding_kind_to_string(f.kind))),
    #("confidence", opt(f.confidence, json.float)),
    #("message", json.string(f.message)),
    #("judgment", opt(f.judgment, json.int)),
    #("status", json.string(model.finding_status_to_string(f.status))),
    #("dismiss_reason", opt(f.dismiss_reason, json.string)),
    #("created_at", json.int(f.created_at)),
    #("delivered_at", opt(f.delivered_at, json.int)),
    #("acked_at", opt(f.acked_at, json.int)),
    #("closed_at", opt(f.closed_at, json.int)),
  ])
}

pub fn encode_comment(c: Comment) -> Json {
  json.object([
    #("id", json.int(c.id)),
    #("item", json.int(c.item)),
    #("author", json.string(author_to_string(c.author))),
    #("body", json.string(c.body)),
    #("pick", opt(c.pick, json.string)),
    #("created_at", json.int(c.created_at)),
    #("sent_at", opt(c.sent_at, json.int)),
    #("acked_at", opt(c.acked_at, json.int)),
  ])
}

fn author_to_string(author: model.CommentAuthor) -> String {
  case author {
    model.HumanAuthor(user) -> "user:" <> int.to_string(user)
    model.AgentAuthor(agent) -> "agent:" <> int.to_string(agent)
  }
}

fn author_from_string(s: String) -> Result(model.CommentAuthor, Nil) {
  case s {
    "user:" <> id -> int.parse(id) |> result.map(model.HumanAuthor)
    "agent:" <> id -> int.parse(id) |> result.map(model.AgentAuthor)
    _ -> Error(Nil)
  }
}

fn encode_event(e: Event) -> Json {
  json.object([
    #("id", json.int(e.id)),
    #("at", json.int(e.at)),
    #("actor", json.string(e.actor)),
    #("item", opt(e.item, json.int)),
    #("type", json.string(e.event_type)),
    #("detail", json.string(e.detail)),
  ])
}

fn encode_judgment(j: Judgment) -> Json {
  json.object([
    #("id", json.int(j.id)),
    #("at", json.int(j.at)),
    #("purpose", json.string(j.purpose)),
    #("item", opt(j.item, json.int)),
    #("request", opt(j.request, json.string)),
    #("response", opt(j.response, json.string)),
    #("latency_ms", json.int(j.latency_ms)),
    #("input_tokens", json.int(j.input_tokens)),
    #("output_tokens", json.int(j.output_tokens)),
    #("error", opt(j.error, json.string)),
  ])
}

fn encode_link(l: McpLink) -> Json {
  json.object([
    #("id", json.int(l.id)),
    #("user", json.int(l.user)),
    #("secret_sha256", json.string(l.secret_sha256)),
    #("label", json.string(l.label)),
    #("pinned_name", opt(l.pinned_name, json.string)),
    #("pinned_project", opt(l.pinned_project, json.string)),
    #("scope", json.string(l.scope)),
    #("created_at", json.int(l.created_at)),
    #("last_used_at", opt(l.last_used_at, json.int)),
    #("last_used_ip", opt(l.last_used_ip, json.string)),
    #("revoked_at", opt(l.revoked_at, json.int)),
  ])
}

fn encode_client(c: OAuthClient) -> Json {
  json.object([
    #("client_id", json.string(c.client_id)),
    #(
      "kind",
      json.string(case c.kind {
        model.Cimd -> "cimd"
        model.Dcr -> "dcr"
      }),
    ),
    #("client_name", json.string(c.client_name)),
    #("redirect_uris", json.array(c.redirect_uris, json.string)),
    #("metadata", json.string(c.metadata)),
    #("fetched_at", opt(c.fetched_at, json.int)),
    #("cache_until", opt(c.cache_until, json.int)),
    #("created_at", json.int(c.created_at)),
  ])
}

fn encode_grant(g: OAuthGrant) -> Json {
  json.object([
    #("id", json.int(g.id)),
    #("client_id", json.string(g.client_id)),
    #("user", json.int(g.user)),
    #("scope", json.string(g.scope)),
    #("created_at", json.int(g.created_at)),
    #("last_used_at", opt(g.last_used_at, json.int)),
    #("last_used_ip", opt(g.last_used_ip, json.string)),
    #("revoked_at", opt(g.revoked_at, json.int)),
  ])
}

fn encode_token(t: OAuthToken) -> Json {
  json.object([
    #("token_sha256", json.string(t.token_sha256)),
    #("grant", json.int(t.grant)),
    #(
      "kind",
      json.string(case t.kind {
        model.AccessToken -> "access"
        model.RefreshToken -> "refresh"
      }),
    ),
    #("family", json.string(t.family)),
    #("resource", json.string(t.resource)),
    #("expires_at", json.int(t.expires_at)),
    #("used_at", opt(t.used_at, json.int)),
  ])
}

// --- decoding ----------------------------------------------------------------

fn nullable(
  name: String,
  inner: Decoder(a),
  next: fn(Option(a)) -> Decoder(b),
) {
  decode.optional_field(name, None, decode.optional(inner), next)
}

fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn enum(from_string: fn(String) -> Result(a, Nil), default: a) -> Decoder(a) {
  use s <- decode.then(decode.string)
  case from_string(s) {
    Ok(v) -> decode.success(v)
    Error(_) -> decode.failure(default, "known value, got " <> s)
  }
}

/// Read the `format` field without decoding the rest.
pub fn format_decoder() -> Decoder(Int) {
  decode.field("format", decode.int, decode.success)
}

pub fn state_decoder() -> Decoder(State) {
  use saved_at <- decode.optional_field("saved_at", 0, decode.int)
  use next_id <- decode.field("next_id", next_ids_decoder())
  use users <- decode.field("users", decode.list(user_decoder()))
  use sessions <- decode.field("web_sessions", decode.list(session_decoder()))
  use agents <- decode.field("agents", decode.list(agent_decoder()))
  use items <- decode.field("items", decode.list(item_decoder()))
  use findings <- decode.field("findings", findings_decoder())
  use events <- decode.field("events", decode.list(event_decoder()))
  use judgments <- decode.field("judgments", decode.list(judgment_decoder()))
  use links <- decode.field("mcp_links", decode.list(link_decoder()))
  use #(clients, grants, tokens) <- decode.field("oauth", {
    use clients <- decode.field("clients", decode.list(client_decoder()))
    use grants <- decode.field("grants", decode.list(grant_decoder()))
    use tokens <- decode.field("tokens", decode.list(token_decoder()))
    decode.success(#(clients, grants, tokens))
  })
  use documents <- decode.optional_field(
    "documents",
    [],
    decode.list(document_decoder()),
  )
  use comments <- decode.optional_field(
    "comments",
    [],
    decode.list(comment_decoder()),
  )
  decode.success(State(
    saved_at:,
    next_id:,
    users: by(users, fn(u) { u.id }),
    web_sessions: by(sessions, fn(s) { s.token_sha256 }),
    agents: by(agents, fn(a) { a.id }),
    items: by(items, fn(i) { i.id }),
    findings: by(findings, fn(f) { f.id }),
    events: list.reverse(events),
    judgments: by(judgments, fn(j) { j.id }),
    mcp_links: by(links, fn(l) { l.id }),
    oauth_clients: by(clients, fn(c) { c.client_id }),
    oauth_grants: by(grants, fn(g) { g.id }),
    oauth_tokens: by(tokens, fn(t) { t.token_sha256 }),
    documents: by(documents, fn(d) { d.id }),
    comments: by(comments, fn(c) { c.id }),
  ))
}

fn by(values: List(a), key: fn(a) -> k) -> dict.Dict(k, a) {
  list.fold(values, dict.new(), fn(acc, v) { dict.insert(acc, key(v), v) })
}

fn next_ids_decoder() -> Decoder(NextIds) {
  use user <- decode.field("user", decode.int)
  use agent <- decode.field("agent", decode.int)
  use item <- decode.field("item", decode.int)
  use finding <- decode.field("finding", decode.int)
  use event <- decode.field("event", decode.int)
  use judgment <- decode.field("judgment", decode.int)
  use link <- decode.field("link", decode.int)
  use grant <- decode.field("grant", decode.int)
  use document <- decode.optional_field("document", 1, decode.int)
  use comment <- decode.optional_field("comment", 1, decode.int)
  decode.success(NextIds(
    user:,
    agent:,
    item:,
    finding:,
    event:,
    judgment:,
    link:,
    grant:,
    document:,
    comment:,
  ))
}

fn user_decoder() -> Decoder(User) {
  use id <- decode.field("id", decode.int)
  use email <- decode.field("email", decode.string)
  use handle <- decode.field("handle", decode.string)
  use nb <- decode.optional_field(
    "notify_browser_non_blocking",
    False,
    decode.bool,
  )
  use created_at <- decode.field("created_at", decode.int)
  use last_login_at <- nullable("last_login_at", decode.int)
  decode.success(User(
    id:,
    email:,
    handle:,
    notify_browser_non_blocking: nb,
    created_at:,
    last_login_at:,
  ))
}

fn session_decoder() -> Decoder(WebSession) {
  use token_sha256 <- decode.field("token_sha256", decode.string)
  use user <- decode.field("user", decode.int)
  use created_at <- decode.field("created_at", decode.int)
  use expires_at <- decode.field("expires_at", decode.int)
  use user_agent <- decode.optional_field("user_agent", "", decode.string)
  decode.success(WebSession(
    token_sha256:,
    user:,
    created_at:,
    expires_at:,
    user_agent:,
  ))
}

fn agent_decoder() -> Decoder(Agent) {
  use id <- decode.field("id", decode.int)
  use owner <- decode.field("owner", decode.int)
  use name <- decode.field("name", decode.string)
  use project <- decode.field("project", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use last_seen_at <- decode.field("last_seen_at", decode.int)
  decode.success(Agent(id:, owner:, name:, project:, created_at:, last_seen_at:))
}

pub fn item_decoder() -> Decoder(Item) {
  use id <- decode.field("id", decode.int)
  use agent <- decode.field("agent", decode.int)
  use kind <- decode.field("kind", enum(model.kind_from_string, model.Task))
  use title <- decode.field("title", decode.string)
  use detail <- decode.optional_field("detail", "", decode.string)
  use blocking <- decode.optional_field("blocking", False, decode.bool)
  use options <- decode.optional_field(
    "options",
    [],
    decode.one_of(decode.list(decode.string), [
      decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
    ]),
  )
  use state <- decode.field(
    "state",
    enum(model.state_from_string, model.Active),
  )
  use importance <- nullable("importance", number())
  use reviewed_at <- nullable("reviewed_at", decode.int)
  use stale_p <- nullable("stale_p", number())
  use overlaps <- nullable("overlaps", decode.int)
  use seen_by <- nullable("seen_by", decode.int)
  use seen_at <- nullable("seen_at", decode.int)
  use hidden_by <- nullable("hidden_by", decode.int)
  use hidden_note <- nullable("hidden_note", decode.string)
  use docs <- decode.optional_field("docs", [], decode.list(decode.int))
  use version <- decode.optional_field("version", 1, decode.int)
  use created_at <- decode.field("created_at", decode.int)
  use updated_at <- decode.field("updated_at", decode.int)
  use closed_at <- nullable("closed_at", decode.int)
  decode.success(Item(
    id:,
    agent:,
    kind:,
    title:,
    detail:,
    blocking:,
    options:,
    state:,
    importance:,
    reviewed_at:,
    stale_p:,
    overlaps:,
    seen_by:,
    seen_at:,
    hidden_by:,
    hidden_note:,
    docs:,
    version:,
    created_at:,
    updated_at:,
    closed_at:,
  ))
}

pub fn document_decoder() -> Decoder(Document) {
  use id <- decode.field("id", decode.int)
  use agent <- decode.field("agent", decode.int)
  use updated_by <- decode.optional_field("updated_by", agent, decode.int)
  use title <- decode.field("title", decode.string)
  // documents from before slugs get one from their title
  use slug <- decode.optional_field(
    "slug",
    model.doc_slug(title),
    decode.string,
  )
  use files <- decode.field(
    "files",
    decode.list({
      use path <- decode.field("path", decode.string)
      use size <- decode.field("size", decode.int)
      use entry <- decode.optional_field("entry", path, decode.string)
      decode.success(DocFile(path:, size:, entry:))
    }),
  )
  use size <- decode.field("size", decode.int)
  use storage_key <- decode.field("storage_key", decode.string)
  use version <- decode.field("version", decode.int)
  use created_at <- decode.field("created_at", decode.int)
  use updated_at <- decode.field("updated_at", decode.int)
  use public <- decode.optional_field(
    "public",
    None,
    decode.optional({
      use nonce <- decode.field("nonce", decode.string)
      use by <- decode.field("by", decode.int)
      use at <- decode.field("at", decode.int)
      use agent <- decode.optional_field(
        "agent",
        None,
        decode.optional(decode.int),
      )
      decode.success(PublicLink(nonce:, by:, agent:, at:))
    }),
  )
  decode.success(Document(
    id:,
    slug:,
    agent:,
    updated_by:,
    title:,
    files:,
    size:,
    storage_key:,
    version:,
    created_at:,
    updated_at:,
    public:,
  ))
}

/// Checks that Huddy no longer runs; their findings are dropped on load.
const retired_finding_kinds = ["wrong_kind", "injection"]

fn findings_decoder() -> Decoder(List(Finding)) {
  decode.list({
    use kind <- decode.field("kind", decode.string)
    case list.contains(retired_finding_kinds, kind) {
      True -> decode.success(None)
      False -> decode.map(finding_decoder(), Some)
    }
  })
  |> decode.map(option.values)
}

fn finding_decoder() -> Decoder(Finding) {
  use id <- decode.field("id", decode.int)
  use agent <- decode.field("agent", decode.int)
  use item <- nullable("item", decode.int)
  use item_version <- nullable("item_version", decode.int)
  use related_item <- nullable("related_item", decode.int)
  use kind <- decode.field(
    "kind",
    enum(model.finding_kind_from_string, model.Unclear),
  )
  use confidence <- nullable("confidence", number())
  use message <- decode.field("message", decode.string)
  use judgment <- nullable("judgment", decode.int)
  use status <- decode.field(
    "status",
    enum(model.finding_status_from_string, model.FindingOpen),
  )
  use dismiss_reason <- nullable("dismiss_reason", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use delivered_at <- nullable("delivered_at", decode.int)
  // Files from before acknowledgements have no `acked_at`. Their delivered
  // findings went out under the old rules, so they count as acked;
  // repeating them all at once would flood the agents.
  use acked_at <- decode.optional_field(
    "acked_at",
    case status {
      model.FindingOpen -> None
      _ -> delivered_at
    },
    decode.optional(decode.int),
  )
  use closed_at <- nullable("closed_at", decode.int)
  decode.success(Finding(
    id:,
    agent:,
    item:,
    item_version:,
    related_item:,
    kind:,
    confidence:,
    message:,
    judgment:,
    status:,
    dismiss_reason:,
    created_at:,
    delivered_at:,
    acked_at:,
    closed_at:,
  ))
}

fn comment_decoder() -> Decoder(Comment) {
  use id <- decode.field("id", decode.int)
  use item <- decode.field("item", decode.int)
  use author <- decode.field(
    "author",
    enum(author_from_string, model.HumanAuthor(0)),
  )
  use body <- decode.field("body", decode.string)
  use pick <- nullable("pick", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use sent_at <- nullable("sent_at", decode.int)
  use acked_at <- nullable("acked_at", decode.int)
  decode.success(Comment(
    id:,
    item:,
    author:,
    body:,
    pick:,
    created_at:,
    sent_at:,
    acked_at:,
  ))
}

fn event_decoder() -> Decoder(Event) {
  use id <- decode.field("id", decode.int)
  use at <- decode.field("at", decode.int)
  use actor <- decode.field("actor", decode.string)
  use item <- nullable("item", decode.int)
  use event_type <- decode.field("type", decode.string)
  use detail <- decode.optional_field("detail", "", decode.string)
  decode.success(Event(id:, at:, actor:, item:, event_type:, detail:))
}

fn judgment_decoder() -> Decoder(Judgment) {
  use id <- decode.field("id", decode.int)
  use at <- decode.field("at", decode.int)
  use purpose <- decode.field("purpose", decode.string)
  use item <- nullable("item", decode.int)
  use request <- nullable("request", decode.string)
  use response <- nullable("response", decode.string)
  use latency_ms <- decode.optional_field("latency_ms", 0, decode.int)
  use input_tokens <- decode.optional_field("input_tokens", 0, decode.int)
  use output_tokens <- decode.optional_field("output_tokens", 0, decode.int)
  use error <- nullable("error", decode.string)
  decode.success(Judgment(
    id:,
    at:,
    purpose:,
    item:,
    request:,
    response:,
    latency_ms:,
    input_tokens:,
    output_tokens:,
    error:,
  ))
}

fn link_decoder() -> Decoder(McpLink) {
  use id <- decode.field("id", decode.int)
  use user <- decode.field("user", decode.int)
  use secret_sha256 <- decode.field("secret_sha256", decode.string)
  use label <- decode.field("label", decode.string)
  use pinned_name <- nullable("pinned_name", decode.string)
  use pinned_project <- nullable("pinned_project", decode.string)
  use scope <- decode.field("scope", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use last_used_at <- nullable("last_used_at", decode.int)
  use last_used_ip <- nullable("last_used_ip", decode.string)
  use revoked_at <- nullable("revoked_at", decode.int)
  decode.success(McpLink(
    id:,
    user:,
    secret_sha256:,
    label:,
    pinned_name:,
    pinned_project:,
    scope:,
    created_at:,
    last_used_at:,
    last_used_ip:,
    revoked_at:,
  ))
}

fn client_decoder() -> Decoder(OAuthClient) {
  use client_id <- decode.field("client_id", decode.string)
  use kind <- decode.field(
    "kind",
    enum(
      fn(s) {
        case s {
          "cimd" -> Ok(model.Cimd)
          "dcr" -> Ok(model.Dcr)
          _ -> Error(Nil)
        }
      },
      model.Dcr,
    ),
  )
  use client_name <- decode.optional_field("client_name", "", decode.string)
  use redirect_uris <- decode.field("redirect_uris", decode.list(decode.string))
  use metadata <- decode.optional_field("metadata", "{}", decode.string)
  use fetched_at <- nullable("fetched_at", decode.int)
  use cache_until <- nullable("cache_until", decode.int)
  use created_at <- decode.field("created_at", decode.int)
  decode.success(OAuthClient(
    client_id:,
    kind:,
    client_name:,
    redirect_uris:,
    metadata:,
    fetched_at:,
    cache_until:,
    created_at:,
  ))
}

fn grant_decoder() -> Decoder(OAuthGrant) {
  use id <- decode.field("id", decode.int)
  use client_id <- decode.field("client_id", decode.string)
  use user <- decode.field("user", decode.int)
  use scope <- decode.field("scope", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use last_used_at <- nullable("last_used_at", decode.int)
  use last_used_ip <- nullable("last_used_ip", decode.string)
  use revoked_at <- nullable("revoked_at", decode.int)
  decode.success(OAuthGrant(
    id:,
    client_id:,
    user:,
    scope:,
    created_at:,
    last_used_at:,
    last_used_ip:,
    revoked_at:,
  ))
}

fn token_decoder() -> Decoder(OAuthToken) {
  use token_sha256 <- decode.field("token_sha256", decode.string)
  use grant <- decode.field("grant", decode.int)
  use kind <- decode.field(
    "kind",
    enum(
      fn(s) {
        case s {
          "access" -> Ok(model.AccessToken)
          "refresh" -> Ok(model.RefreshToken)
          _ -> Error(Nil)
        }
      },
      model.AccessToken,
    ),
  )
  use family <- decode.field("family", decode.string)
  use resource <- decode.field("resource", decode.string)
  use expires_at <- decode.field("expires_at", decode.int)
  use used_at <- nullable("used_at", decode.int)
  decode.success(OAuthToken(
    token_sha256:,
    grant:,
    kind:,
    family:,
    resource:,
    expires_at:,
    used_at:,
  ))
}

/// Referential integrity: every reference must point at an existing record.
pub fn check_references(state: State) -> Result(Nil, String) {
  let missing = fn(what: String, id: Int) {
    Error("dangling reference: " <> what <> " " <> int.to_string(id))
  }
  let check_all = fn(values: List(a), check: fn(a) -> Result(Nil, String)) {
    list.try_each(values, check)
  }
  let has_user = fn(id) { dict.has_key(state.users, id) }
  let has_item = fn(id) { dict.has_key(state.items, id) }
  let opt_item = fn(what, id: Option(Int)) {
    case id {
      option.Some(i) ->
        case has_item(i) {
          True -> Ok(Nil)
          False -> missing(what, i)
        }
      None -> Ok(Nil)
    }
  }
  let opt_user = fn(what, id: Option(Int)) {
    case id {
      option.Some(u) ->
        case has_user(u) {
          True -> Ok(Nil)
          False -> missing(what, u)
        }
      None -> Ok(Nil)
    }
  }
  let check = fn(ok: Bool, what: String, id: Int) {
    case ok {
      True -> Ok(Nil)
      False -> missing(what, id)
    }
  }
  let result = {
    let r1 =
      check_all(dict.values(state.web_sessions), fn(s) {
        check(has_user(s.user), "session user", s.user)
      })
    let r2 =
      check_all(dict.values(state.agents), fn(a) {
        check(has_user(a.owner), "agent owner", a.owner)
      })
    let r3 =
      check_all(dict.values(state.items), fn(i) {
        case check(dict.has_key(state.agents, i.agent), "item agent", i.agent) {
          Ok(_) ->
            case opt_item("item overlaps", i.overlaps) {
              Ok(_) ->
                case opt_user("item seen_by", i.seen_by) {
                  Ok(_) ->
                    case opt_user("item hidden_by", i.hidden_by) {
                      Ok(_) ->
                        check_all(i.docs, fn(d) {
                          check(
                            dict.has_key(state.documents, d),
                            "item document",
                            d,
                          )
                        })
                      e -> e
                    }
                  e -> e
                }
              e -> e
            }
          e -> e
        }
      })
    let r4 =
      check_all(dict.values(state.findings), fn(f) {
        case
          check(dict.has_key(state.agents, f.agent), "finding agent", f.agent)
        {
          Ok(_) ->
            case opt_item("finding item", f.item) {
              Ok(_) -> opt_item("finding related_item", f.related_item)
              e -> e
            }
          e -> e
        }
      })
    let r5 =
      check_all(dict.values(state.mcp_links), fn(l) {
        check(has_user(l.user), "link user", l.user)
      })
    let r6 =
      check_all(dict.values(state.oauth_grants), fn(g) {
        check(has_user(g.user), "grant user", g.user)
      })
    let r7 =
      check_all(dict.values(state.oauth_tokens), fn(t) {
        check(dict.has_key(state.oauth_grants, t.grant), "token grant", t.grant)
      })
    let r8 =
      check_all(dict.values(state.documents), fn(d) {
        case
          check(dict.has_key(state.agents, d.agent), "document agent", d.agent)
        {
          Ok(_) ->
            case
              check(
                dict.has_key(state.agents, d.updated_by),
                "document updated_by",
                d.updated_by,
              )
            {
              Ok(_) ->
                case
                  opt_user(
                    "document public link",
                    option.map(d.public, fn(p) { p.by }),
                  )
                {
                  Ok(_) ->
                    case option.then(d.public, fn(p) { p.agent }) {
                      Some(a) ->
                        check(
                          dict.has_key(state.agents, a),
                          "document public link agent",
                          a,
                        )
                      None -> Ok(Nil)
                    }
                  e -> e
                }
              e -> e
            }
          e -> e
        }
      })
    let r9 =
      check_all(dict.values(state.comments), fn(c) {
        case check(has_item(c.item), "comment item", c.item) {
          Ok(_) ->
            case c.author {
              model.HumanAuthor(u) -> check(has_user(u), "comment author", u)
              model.AgentAuthor(a) ->
                check(dict.has_key(state.agents, a), "comment author", a)
            }
          e -> e
        }
      })
    [r1, r2, r3, r4, r5, r6, r7, r8, r9]
  }
  list.try_each(result, fn(r) { r })
}
