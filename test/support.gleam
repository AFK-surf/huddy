//// Test fixtures.

import huddy/blob
import huddy/config.{type Config}
import huddy/model.{type State}
import huddy/state

@external(erlang, "huddy_test_ffi", "putenv")
pub fn putenv(name: String, value: String) -> Nil

@external(erlang, "huddy_test_ffi", "tmp_dir")
pub fn tmp_dir() -> String

@external(erlang, "huddy_test_ffi", "write_file")
pub fn write_file(path: String, data: BitArray) -> Nil

pub fn config(dir: String, port: Int) -> Config {
  config.Config(
    team_name: "Test Team",
    base_url: "http://localhost:" <> int_to_string(port),
    listen: "127.0.0.1",
    port:,
    trusted_proxies: [],
    storage: config.Storage(
      path: blob.File(dir <> "/huddy.json"),
      backup_dir: blob.File(dir <> "/backups"),
      backup_keep: 3,
      documents_dir: blob.File(dir <> "/documents"),
      flush_ms: 20,
      idle_flush_seconds: 1,
      warn_mb: 10,
    ),
    secret_key: "test-secret-key-0123456789abcdefghijklmnop",
    auth: config.Auth(
      allowed_domains: ["acme.dev"],
      allowed_emails: ["guest@example.com"],
      code_ttl_minutes: 10,
      code_max_attempts: 3,
      session_ttl_days: 30,
    ),
    email: config.Email(
      from: "Huddy <huddy@acme.dev>",
      transport: config.LogTransport,
    ),
    mcp: config.Mcp(
      secret_urls: True,
      access_token_ttl_minutes: 60,
      refresh_token_ttl_days: 30,
      client_id_metadata_documents: True,
      dynamic_client_registration: True,
      trusted_client_hosts: [],
    ),
    decision_model: config.DecisionModel(
      provider: "typesafe",
      base_url: "http://127.0.0.1:1",
      endpoint: "http://127.0.0.1:1/v1/systemone",
      model: "jev-latest",
      api_key: "test",
      enabled: True,
      timeout_ms: 1000,
    ),
    review: config.Review(..config.default_review(), wait_ms: 2000),
    notify: config.Notify(browser: True),
    display: config.default_display(),
    limits: config.Limits(
      title_max_chars: 120,
      detail_max_chars: 2000,
      writes_per_agent_per_minute: 1000,
      document_max_mb: 2,
      comment_max_chars: 1000,
      comments_per_item: 100,
      comments_per_user_per_minute: 1000,
    ),
    retention: config.Retention(30, 90, 14, 90, 3),
  )
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String

/// A state with two users, each with one agent.
pub fn two_agents(now: Int) -> #(State, Int, Int) {
  let s = model.empty_state()
  let #(s, alice) = state.create_user(s, "alice@acme.dev", now)
  let #(s, bob) = state.create_user(s, "bob@acme.dev", now)
  let #(s, a) = state.ensure_agent(s, alice.id, "codex", "huddy", now)
  let #(s, b) = state.ensure_agent(s, bob.id, "claude-code", "api", now)
  #(s, a.id, b.id)
}

pub fn task(title: String) -> state.NewItem {
  state.NewItem(model.Task, title, "", False, [], [])
}

pub fn decision(title: String, blocking: Bool) -> state.NewItem {
  state.NewItem(model.Decision, title, "", blocking, [], [])
}

pub fn goal(title: String) -> state.NewItem {
  state.NewItem(model.Goal, title, "", False, [], [])
}
