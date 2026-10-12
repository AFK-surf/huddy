//// The single JSON configuration file. Decoded and validated at startup;
//// any string value may instead be `{"$env": "NAME"}`.

import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import huddy/blob.{type Location}
import huddy/net
import huddy/s3
import huddy/sys

pub type Config {
  Config(
    team_name: String,
    base_url: String,
    listen: String,
    port: Int,
    trusted_proxies: List(net.Cidr),
    storage: Storage,
    secret_key: String,
    auth: Auth,
    email: Email,
    mcp: Mcp,
    decision_model: DecisionModel,
    review: Review,
    notify: Notify,
    display: Display,
    limits: Limits,
    retention: Retention,
  )
}

pub type Storage {
  Storage(
    /// a local path, or `s3://bucket/key` (see `storage.s3`)
    path: Location,
    backup_dir: Location,
    backup_keep: Int,
    /// where document files live (default: `documents` next to `path`)
    documents_dir: Location,
    flush_ms: Int,
    idle_flush_seconds: Int,
    warn_mb: Int,
  )
}

pub type Auth {
  Auth(
    allowed_domains: List(String),
    allowed_emails: List(String),
    code_ttl_minutes: Int,
    code_max_attempts: Int,
    session_ttl_days: Int,
  )
}

pub type Email {
  Email(from: String, transport: Transport)
}

pub type Transport {
  Smtp(host: String, port: Int, tls: String, username: String, password: String)
  LogTransport
}

pub type Mcp {
  Mcp(
    secret_urls: Bool,
    access_token_ttl_minutes: Int,
    refresh_token_ttl_days: Int,
    client_id_metadata_documents: Bool,
    dynamic_client_registration: Bool,
    trusted_client_hosts: List(String),
  )
}

pub type DecisionModel {
  DecisionModel(
    provider: String,
    base_url: String,
    /// Full URL of the decisions endpoint. Defaults to `base_url` +
    /// "/v1/systemone" (TypeSafe); OpenRouter uses
    /// "https://openrouter.ai/api/alpha/decisions".
    endpoint: String,
    model: String,
    api_key: String,
    enabled: Bool,
    timeout_ms: Int,
  )
}

pub type Thresholds {
  Thresholds(
    unclear: Float,
    not_a_question: Float,
    duplicate: Float,
    overlap: Float,
    stale: Float,
  )
}

pub type Review {
  Review(
    wait_ms: Int,
    thresholds: Thresholds,
    sweep_interval_minutes: Int,
    sweep_idle_hours: Int,
    untouched_days: Int,
    open_tasks_guideline: Int,
    open_decisions_guideline: Int,
    dismiss_cooldown_hours: Int,
  )
}

pub type Notify {
  Notify(browser: Bool)
}

pub type Display {
  Display(
    slots_goals: Int,
    slots_tasks: Int,
    slots_decisions: Int,
    cap_tasks: Int,
    cap_decisions: Int,
    agent_away_after_minutes: Int,
    rerank_interval_seconds: Int,
  )
}

pub type Limits {
  Limits(
    title_max_chars: Int,
    detail_max_chars: Int,
    writes_per_agent_per_minute: Int,
    /// total size of a document's files, unzipped
    document_max_mb: Int,
    comment_max_chars: Int,
    comments_per_item: Int,
    comments_per_user_per_minute: Int,
  )
}

pub type Retention {
  Retention(
    closed_items_days: Int,
    events_days: Int,
    judgment_detail_days: Int,
    judgments_days: Int,
    /// close an agent's open items once it hasn't been seen this long;
    /// 0 never does
    inactive_agent_days: Int,
  )
}

// --- loading ---------------------------------------------------------------

pub fn load(path: String) -> Result(Config, String) {
  use bits <- result.try(
    sys.read_file(path)
    |> result.map_error(fn(e) { "cannot read config " <> path <> ": " <> e }),
  )
  parse(bits)
}

pub fn parse(bits: BitArray) -> Result(Config, String) {
  use config <- result.try(
    json.parse_bits(bits, decoder())
    |> result.map_error(describe_json_error),
  )
  validate(config)
}

fn describe_json_error(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "config: unexpected end of input"
    json.UnexpectedByte(b) -> "config: invalid JSON near " <> b
    json.UnexpectedSequence(s) -> "config: invalid JSON near " <> s
    json.UnableToDecode(errors) ->
      errors
      |> list.map(fn(e) {
        let decode.DecodeError(expected:, found:, path:) = e
        let where = case path {
          [] -> "top level"
          _ -> string.join(path, ".")
        }
        "config: " <> where <> ": expected " <> expected <> ", found " <> found
      })
      |> string.join("\n")
  }
}

/// A string, or `{"$env": "NAME"}` resolved from the environment.
fn str() -> Decoder(String) {
  use value <- decode.then(decode.dynamic)
  case decode.run(value, decode.string) {
    Ok(s) -> decode.success(s)
    Error(_) ->
      case decode.run(value, decode.at(["$env"], decode.string)) {
        Ok(name) ->
          case sys.getenv(name) {
            Ok(v) -> decode.success(v)
            Error(_) ->
              decode.failure(
                "",
                "String (environment variable " <> name <> " is unset)",
              )
          }
        Error(_) -> decode.failure("", "String or {\"$env\": NAME}")
      }
  }
}

fn opt(
  name: String,
  default: a,
  decoder: Decoder(a),
  next: fn(a) -> Decoder(b),
) -> Decoder(b) {
  decode.optional_field(name, default, decoder, next)
}

fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn section(
  name: String,
  inner: Decoder(a),
  default: a,
  next: fn(a) -> Decoder(b),
) {
  decode.optional_field(name, default, inner, next)
}

pub fn decoder() -> Decoder(Config) {
  use #(team_name, base_url) <- decode.field("team", {
    use name <- decode.field("name", str())
    use base_url <- decode.field("base_url", str())
    decode.success(#(name, base_url))
  })
  use #(listen, port, trusted) <- section(
    "server",
    {
      use listen <- opt("listen", "127.0.0.1", str())
      use port <- opt("port", 8080, decode.int)
      use trusted <- opt("trusted_proxies", [], decode.list(str()))
      decode.success(#(listen, port, trusted))
    },
    #("127.0.0.1", 8080, []),
  )
  use storage <- decode.field("storage", storage_decoder())
  use secret_key <- decode.field("secret_key", str())
  use auth <- decode.field("auth", auth_decoder())
  use email <- decode.field("email", email_decoder())
  use mcp <- section("mcp", mcp_decoder(), default_mcp())
  use decision_model <- section(
    "decision_model",
    decision_model_decoder(),
    default_decision_model(),
  )
  use review <- section("review", review_decoder(), default_review())
  use notify <- section("notify", notify_decoder(), Notify(browser: True))
  use display <- section("display", display_decoder(), default_display())
  use limits <- section(
    "limits",
    limits_decoder(),
    Limits(120, 2000, 12, 20, 1000, 100, 12),
  )
  use retention <- section(
    "retention",
    retention_decoder(),
    Retention(30, 90, 14, 90, 3),
  )
  use trusted_proxies <- decode.then(
    case list.try_map(trusted, net.parse_cidr) {
      Ok(cidrs) -> decode.success(cidrs)
      Error(_) ->
        decode.failure(
          [],
          "server.trusted_proxies: IP addresses or CIDR ranges",
        )
    },
  )
  decode.success(Config(
    team_name:,
    base_url:,
    listen:,
    port:,
    trusted_proxies:,
    storage:,
    secret_key:,
    auth:,
    email:,
    mcp:,
    decision_model:,
    review:,
    notify:,
    display:,
    limits:,
    retention:,
  ))
}

fn storage_decoder() -> Decoder(Storage) {
  use s3 <- section("s3", s3_decoder(), default_s3())
  use path <- decode.field("path", location(s3))
  use backup_dir <- opt("backup_dir", None, decode.map(location(s3), Some))
  use documents_dir <- opt(
    "documents_dir",
    None,
    decode.map(location(s3), Some),
  )
  use backup_keep <- opt("backup_keep", 7, decode.int)
  use flush_ms <- opt("flush_ms", 100, decode.int)
  use idle_flush_seconds <- opt("idle_flush_seconds", 5, decode.int)
  use warn_mb <- opt("warn_mb", 10, decode.int)
  let backup_dir =
    option.lazy_unwrap(backup_dir, fn() {
      blob.child(blob.parent(path), "backups")
    })
  let documents_dir =
    option.lazy_unwrap(documents_dir, fn() {
      blob.child(blob.parent(path), "documents")
    })
  decode.success(Storage(
    path:,
    backup_dir:,
    backup_keep:,
    documents_dir:,
    flush_ms:,
    idle_flush_seconds:,
    warn_mb:,
  ))
}

fn location(s3: s3.Config) -> Decoder(Location) {
  use text <- decode.then(str())
  case blob.parse(text, s3) {
    Ok(location) -> decode.success(location)
    Error(_) -> decode.failure(blob.File(""), "a path or s3://bucket/key")
  }
}

/// S3 settings, used by `s3://` paths. Region and credentials default to the
/// standard AWS environment variables; the endpoint defaults to AWS S3 in
/// that region.
fn s3_decoder() -> Decoder(s3.Config) {
  let default = default_s3()
  use region <- opt("region", default.region, str())
  use endpoint <- opt("endpoint", "", str())
  use path_style <- opt("path_style", endpoint != "", decode.bool)
  use access_key_id <- opt("access_key_id", default.access_key_id, str())
  use secret_access_key <- opt(
    "secret_access_key",
    default.secret_access_key,
    str(),
  )
  use session_token <- opt("session_token", default.session_token, str())
  let endpoint = case endpoint {
    "" -> Ok(#(http.Https, "s3." <> region <> ".amazonaws.com", None))
    url -> parse_endpoint(url)
  }
  case endpoint {
    Ok(#(scheme, host, port)) ->
      decode.success(s3.Config(
        region:,
        scheme:,
        host:,
        port:,
        path_style:,
        access_key_id:,
        secret_access_key:,
        session_token:,
      ))
    Error(_) ->
      decode.failure(default, "S3 settings with an http(s) endpoint URL")
  }
}

fn default_s3() -> s3.Config {
  let env = fn(names) { list.find_map(names, sys.getenv) |> result.unwrap("") }
  let region = case env(["AWS_REGION", "AWS_DEFAULT_REGION"]) {
    "" -> "us-east-1"
    region -> region
  }
  s3.Config(
    region:,
    scheme: http.Https,
    host: "s3." <> region <> ".amazonaws.com",
    port: None,
    path_style: False,
    access_key_id: env(["AWS_ACCESS_KEY_ID"]),
    secret_access_key: env(["AWS_SECRET_ACCESS_KEY"]),
    session_token: env(["AWS_SESSION_TOKEN"]),
  )
}

fn parse_endpoint(
  url: String,
) -> Result(#(http.Scheme, String, Option(Int)), Nil) {
  use parsed <- result.try(uri.parse(strip_trailing_slash(url)))
  use scheme <- result.try(case parsed.scheme {
    Some("https") -> Ok(http.Https)
    Some("http") -> Ok(http.Http)
    _ -> Error(Nil)
  })
  use host <- result.try(option.to_result(parsed.host, Nil))
  use _ <- result.try(case parsed.path, host {
    "", _ if host != "" -> Ok(Nil)
    _, _ -> Error(Nil)
  })
  // Drop the scheme's default port, so the signed Host header matches the one
  // the HTTP client sends.
  let port = case scheme, parsed.port {
    http.Https, Some(443) | http.Http, Some(80) -> None
    _, port -> port
  }
  Ok(#(scheme, host, port))
}

fn auth_decoder() -> Decoder(Auth) {
  use domains <- opt("allowed_domains", [], decode.list(str()))
  use emails <- opt("allowed_emails", [], decode.list(str()))
  use code_ttl_minutes <- opt("code_ttl_minutes", 10, decode.int)
  use code_max_attempts <- opt("code_max_attempts", 5, decode.int)
  use session_ttl_days <- opt("session_ttl_days", 30, decode.int)
  decode.success(Auth(
    allowed_domains: list.map(domains, string.lowercase),
    allowed_emails: list.map(emails, string.lowercase),
    code_ttl_minutes:,
    code_max_attempts:,
    session_ttl_days:,
  ))
}

fn email_decoder() -> Decoder(Email) {
  use from <- decode.field("from", str())
  use transport <- opt("transport", "log", str())
  case transport {
    "smtp" -> {
      use smtp <- decode.field("smtp", {
        use host <- decode.field("host", str())
        use port <- opt("port", 587, decode.int)
        use tls <- opt("tls", "starttls", str())
        use username <- opt("username", "", str())
        use password <- opt("password", "", str())
        decode.success(Smtp(host:, port:, tls:, username:, password:))
      })
      decode.success(Email(from:, transport: smtp))
    }
    "log" -> decode.success(Email(from:, transport: LogTransport))
    other ->
      decode.failure(
        Email(from:, transport: LogTransport),
        "\"smtp\" or \"log\", got " <> other,
      )
  }
}

fn default_mcp() -> Mcp {
  Mcp(
    secret_urls: True,
    access_token_ttl_minutes: 60,
    refresh_token_ttl_days: 30,
    client_id_metadata_documents: True,
    dynamic_client_registration: True,
    trusted_client_hosts: [],
  )
}

fn mcp_decoder() -> Decoder(Mcp) {
  let d = default_mcp()
  use secret_urls <- opt("secret_urls", d.secret_urls, decode.bool)
  use oauth <- opt("oauth", #(60, 30, True, True, []), {
    use a <- opt("access_token_ttl_minutes", 60, decode.int)
    use r <- opt("refresh_token_ttl_days", 30, decode.int)
    use cimd <- opt("client_id_metadata_documents", True, decode.bool)
    use dcr <- opt("dynamic_client_registration", True, decode.bool)
    use hosts <- opt("trusted_client_hosts", [], decode.list(str()))
    decode.success(#(a, r, cimd, dcr, hosts))
  })
  let #(a, r, cimd, dcr, hosts) = oauth
  decode.success(Mcp(
    secret_urls:,
    access_token_ttl_minutes: a,
    refresh_token_ttl_days: r,
    client_id_metadata_documents: cimd,
    dynamic_client_registration: dcr,
    trusted_client_hosts: list.map(hosts, string.lowercase),
  ))
}

fn default_decision_model() -> DecisionModel {
  DecisionModel(
    provider: "typesafe",
    base_url: "https://api.typesafe.ai",
    endpoint: "https://api.typesafe.ai/v1/systemone",
    model: "jev-latest",
    api_key: "",
    enabled: False,
    timeout_ms: 4000,
  )
}

fn decision_model_decoder() -> Decoder(DecisionModel) {
  use provider <- opt("provider", "typesafe", str())
  use base_url <- opt("base_url", "https://api.typesafe.ai", str())
  use endpoint <- opt("endpoint", "", str())
  use model <- opt("model", "jev-latest", str())
  use api_key <- opt("api_key", "", str())
  use enabled <- opt("enabled", True, decode.bool)
  use timeout_ms <- opt("timeout_ms", 4000, decode.int)
  decode.success(DecisionModel(
    provider:,
    base_url: strip_trailing_slash(base_url),
    endpoint: case endpoint {
      "" -> strip_trailing_slash(base_url) <> "/v1/systemone"
      e -> e
    },
    model:,
    api_key:,
    enabled:,
    timeout_ms:,
  ))
}

pub fn default_thresholds() -> Thresholds {
  Thresholds(
    unclear: 0.4,
    not_a_question: 0.4,
    duplicate: 0.75,
    overlap: 0.7,
    stale: 0.6,
  )
}

pub fn default_review() -> Review {
  Review(
    wait_ms: 2500,
    thresholds: default_thresholds(),
    sweep_interval_minutes: 15,
    sweep_idle_hours: 2,
    untouched_days: 3,
    open_tasks_guideline: 5,
    open_decisions_guideline: 3,
    dismiss_cooldown_hours: 24,
  )
}

fn review_decoder() -> Decoder(Review) {
  let d = default_review()
  let t = d.thresholds
  use wait_ms <- opt("wait_ms", d.wait_ms, decode.int)
  use thresholds <- opt("thresholds", t, {
    use unclear <- opt("unclear", t.unclear, number())
    use not_a_question <- opt("not_a_question", t.not_a_question, number())
    use duplicate <- opt("duplicate", t.duplicate, number())
    use overlap <- opt("overlap", t.overlap, number())
    use stale <- opt("stale", t.stale, number())
    decode.success(Thresholds(
      unclear:,
      not_a_question:,
      duplicate:,
      overlap:,
      stale:,
    ))
  })
  use sweep_interval_minutes <- opt(
    "sweep_interval_minutes",
    d.sweep_interval_minutes,
    decode.int,
  )
  use sweep_idle_hours <- opt(
    "sweep_idle_hours",
    d.sweep_idle_hours,
    decode.int,
  )
  use untouched_days <- opt("untouched_days", d.untouched_days, decode.int)
  use open_tasks_guideline <- opt(
    "open_tasks_guideline",
    d.open_tasks_guideline,
    decode.int,
  )
  use open_decisions_guideline <- opt(
    "open_decisions_guideline",
    d.open_decisions_guideline,
    decode.int,
  )
  use dismiss_cooldown_hours <- opt(
    "dismiss_cooldown_hours",
    d.dismiss_cooldown_hours,
    decode.int,
  )
  decode.success(Review(
    wait_ms:,
    thresholds:,
    sweep_interval_minutes:,
    sweep_idle_hours:,
    untouched_days:,
    open_tasks_guideline:,
    open_decisions_guideline:,
    dismiss_cooldown_hours:,
  ))
}

fn notify_decoder() -> Decoder(Notify) {
  use browser <- opt("browser", True, decode.bool)
  decode.success(Notify(browser:))
}

pub fn default_display() -> Display {
  Display(
    slots_goals: 8,
    slots_tasks: 12,
    slots_decisions: 6,
    cap_tasks: 3,
    cap_decisions: 2,
    agent_away_after_minutes: 120,
    rerank_interval_seconds: 30,
  )
}

fn display_decoder() -> Decoder(Display) {
  let d = default_display()
  use slots <- opt(
    "slots",
    #(d.slots_goals, d.slots_tasks, d.slots_decisions),
    {
      use g <- opt("goals", d.slots_goals, decode.int)
      use t <- opt("tasks", d.slots_tasks, decode.int)
      use dd <- opt("decisions", d.slots_decisions, decode.int)
      decode.success(#(g, t, dd))
    },
  )
  use cap <- opt("per_agent_cap", #(d.cap_tasks, d.cap_decisions), {
    use t <- opt("tasks", d.cap_tasks, decode.int)
    use dd <- opt("decisions", d.cap_decisions, decode.int)
    decode.success(#(t, dd))
  })
  use away <- opt(
    "agent_away_after_minutes",
    d.agent_away_after_minutes,
    decode.int,
  )
  use rerank <- opt(
    "rerank_interval_seconds",
    d.rerank_interval_seconds,
    decode.int,
  )
  decode.success(Display(
    slots_goals: slots.0,
    slots_tasks: slots.1,
    slots_decisions: slots.2,
    cap_tasks: cap.0,
    cap_decisions: cap.1,
    agent_away_after_minutes: away,
    rerank_interval_seconds: rerank,
  ))
}

fn limits_decoder() -> Decoder(Limits) {
  use t <- opt("title_max_chars", 120, decode.int)
  use d <- opt("detail_max_chars", 2000, decode.int)
  use w <- opt("writes_per_agent_per_minute", 12, decode.int)
  use m <- opt("document_max_mb", 20, decode.int)
  use cm <- opt("comment_max_chars", 1000, decode.int)
  use ci <- opt("comments_per_item", 100, decode.int)
  use cu <- opt("comments_per_user_per_minute", 12, decode.int)
  decode.success(Limits(
    title_max_chars: t,
    detail_max_chars: d,
    writes_per_agent_per_minute: w,
    document_max_mb: m,
    comment_max_chars: cm,
    comments_per_item: ci,
    comments_per_user_per_minute: cu,
  ))
}

fn retention_decoder() -> Decoder(Retention) {
  use c <- opt("closed_items_days", 30, decode.int)
  use e <- opt("events_days", 90, decode.int)
  use jd <- opt("judgment_detail_days", 14, decode.int)
  use j <- opt("judgments_days", 90, decode.int)
  use ia <- opt("inactive_agent_days", 3, decode.int)
  decode.success(Retention(
    closed_items_days: c,
    events_days: e,
    judgment_detail_days: jd,
    judgments_days: j,
    inactive_agent_days: ia,
  ))
}

// --- validation ------------------------------------------------------------

fn strip_trailing_slash(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> strip_trailing_slash(string.drop_end(url, 1))
    False -> url
  }
}

fn validate(config: Config) -> Result(Config, String) {
  let base_url = strip_trailing_slash(config.base_url)
  use parsed <- result.try(
    uri.parse(base_url)
    |> result.replace_error("config: team.base_url is not a URL"),
  )
  let host = option.unwrap(parsed.host, "")
  let local = host == "localhost" || host == "127.0.0.1" || host == "[::1]"
  use _ <- result.try(case parsed.scheme, local {
    Some("https"), _ -> Ok(Nil)
    Some("http"), True -> Ok(Nil)
    _, _ ->
      Error(
        "config: team.base_url must use https (http is only allowed for localhost)",
      )
  })
  use _ <- result.try(case parsed.path {
    "" | "/" -> Ok(Nil)
    _ -> Error("config: team.base_url must not have a path")
  })
  use _ <- result.try(case string.length(config.secret_key) >= 32 {
    True -> Ok(Nil)
    False -> Error("config: secret_key must be at least 32 characters")
  })
  use _ <- result.try(
    case config.auth.allowed_domains, config.auth.allowed_emails {
      [], [] ->
        Error(
          "config: auth.allowed_domains or auth.allowed_emails must list at least one entry",
        )
      _, _ -> Ok(Nil)
    },
  )
  use _ <- result.try(validate_storage(config.storage))
  use _ <- result.try(case config.limits.document_max_mb {
    n if n >= 1 && n <= 1000 -> Ok(Nil)
    _ -> Error("config: limits.document_max_mb must be between 1 and 1000")
  })
  use _ <- result.try(case config.limits.comment_max_chars {
    n if n >= 1 && n <= 10_000 -> Ok(Nil)
    _ -> Error("config: limits.comment_max_chars must be between 1 and 10000")
  })
  use _ <- result.try(
    case
      config.limits.comments_per_item >= 1,
      config.limits.comments_per_user_per_minute >= 1
    {
      True, True -> Ok(Nil)
      _, _ ->
        Error(
          "config: limits.comments_per_item and limits.comments_per_user_per_minute must be at least 1",
        )
    },
  )
  use _ <- result.try(
    case config.decision_model.enabled, config.decision_model.api_key {
      True, "" ->
        Error(
          "config: decision_model.api_key is required when decision_model.enabled is true",
        )
      _, _ -> Ok(Nil)
    },
  )
  Ok(Config(..config, base_url:))
}

fn validate_storage(storage: Storage) -> Result(Nil, String) {
  let objects =
    [storage.path, storage.backup_dir, storage.documents_dir]
    |> list.filter_map(fn(location) {
      case location {
        blob.Object(s3:, ..) -> Ok(s3)
        blob.File(_) -> Error(Nil)
      }
    })
  use _ <- result.try(case storage.path {
    blob.Object(key: "", ..) ->
      Error("config: storage.path must name an object: s3://bucket/key")
    _ -> Ok(Nil)
  })
  case objects {
    [s3, ..] if s3.access_key_id == "" || s3.secret_access_key == "" ->
      Error(
        "config: s3:// storage needs credentials: set storage.s3.access_key_id "
        <> "and storage.s3.secret_access_key, or AWS_ACCESS_KEY_ID and "
        <> "AWS_SECRET_ACCESS_KEY",
      )
    _ -> Ok(Nil)
  }
}

// --- helpers used across the app ---------------------------------------------

/// Is this (already lowercased) email allowed to sign in?
pub fn email_allowed(config: Config, email: String) -> Bool {
  let email = string.lowercase(string.trim(email))
  case valid_email_syntax(email), string.split_once(email, "@") {
    True, Ok(#(local, domain)) if local != "" && domain != "" ->
      list.contains(config.auth.allowed_emails, email)
      || list.any(config.auth.allowed_domains, fn(allowed) {
        case string.starts_with(allowed, "*.") {
          True -> string.ends_with(domain, string.drop_start(allowed, 1))
          False -> domain == allowed
        }
      })
    _, _ -> False
  }
}

/// Printable ASCII only (no spaces or control characters, so nothing can
/// smuggle a header into an e-mail), exactly one "@", at most 254 bytes.
pub fn valid_email_syntax(email: String) -> Bool {
  string.byte_size(email) <= 254
  && list.length(string.split(email, "@")) == 2
  && string.to_utf_codepoints(email)
  |> list.all(fn(cp) {
    let n = string.utf_codepoint_to_int(cp)
    n > 32 && n < 127 && n != 34 && n != 60 && n != 62 && n != 44
  })
}

/// The canonical MCP resource URI (the OAuth audience).
pub fn mcp_resource(config: Config) -> String {
  config.base_url <> "/mcp"
}

pub fn origin_of(url: String) -> Option(String) {
  case uri.parse(url) {
    Ok(uri.Uri(scheme: Some(scheme), host: Some(host), port: port, ..)) ->
      Some(
        scheme
        <> "://"
        <> host
        <> case port {
          Some(p) -> ":" <> int.to_string(p)
          None -> ""
        },
      )
    _ -> None
  }
}
