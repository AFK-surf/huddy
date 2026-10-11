import gleam/bit_array
import gleam/string
import huddy/blob
import huddy/config
import support

fn parse(text: String) -> Result(config.Config, String) {
  config.parse(bit_array.from_string(text))
}

const minimal =
  "{
  \"team\": { \"name\": \"Acme\", \"base_url\": \"https://huddy.acme.dev/\" },
  \"storage\": { \"path\": \"/var/lib/huddy/huddy.json\" },
  \"secret_key\": \"0123456789abcdef0123456789abcdef\",
  \"auth\": { \"allowed_domains\": [\"Acme.dev\"] },
  \"email\": { \"from\": \"Huddy <huddy@acme.dev>\" },
  \"decision_model\": { \"enabled\": false }
}"

pub fn minimal_config_gets_defaults_test() {
  let assert Ok(c) = parse(minimal)
  assert c.base_url == "https://huddy.acme.dev"
  assert c.port == 8080
  assert c.storage.backup_dir == blob.File("/var/lib/huddy/backups")
  assert c.storage.flush_ms == 100
  assert c.auth.allowed_domains == ["acme.dev"]
  assert c.email.transport == config.LogTransport
  assert c.display.slots_tasks == 12
  assert c.review.thresholds.stale == 0.6
  assert config.mcp_resource(c) == "https://huddy.acme.dev/mcp"
}

pub fn env_indirection_test() {
  support.putenv("HUDDY_TEST_SECRET", "env-secret-0123456789abcdef0123456789")
  let text =
    string.replace(
      minimal,
      "\"0123456789abcdef0123456789abcdef\"",
      "{ \"$env\": \"HUDDY_TEST_SECRET\" }",
    )
  let assert Ok(c) = parse(text)
  assert c.secret_key == "env-secret-0123456789abcdef0123456789"
}

pub fn missing_env_variable_is_reported_test() {
  let text =
    string.replace(
      minimal,
      "\"0123456789abcdef0123456789abcdef\"",
      "{ \"$env\": \"HUDDY_TEST_DOES_NOT_EXIST\" }",
    )
  let assert Error(message) = parse(text)
  assert string.contains(message, "HUDDY_TEST_DOES_NOT_EXIST")
  assert string.contains(message, "secret_key")
}

pub fn http_base_url_only_for_localhost_test() {
  let text =
    string.replace(minimal, "https://huddy.acme.dev/", "http://huddy.acme.dev")
  let assert Error(message) = parse(text)
  assert string.contains(message, "https")
  let local =
    string.replace(minimal, "https://huddy.acme.dev/", "http://localhost:8080")
  let assert Ok(_) = parse(local)
}

pub fn short_secret_and_empty_allowlist_rejected_test() {
  let assert Error(_) =
    parse(string.replace(minimal, "0123456789abcdef0123456789abcdef", "short"))
  let assert Error(message) =
    parse(string.replace(minimal, "[\"Acme.dev\"]", "[]"))
  assert string.contains(message, "allowed")
}

pub fn decision_model_needs_key_when_enabled_test() {
  let assert Error(message) =
    parse(string.replace(
      minimal,
      "{ \"enabled\": false }",
      "{ \"enabled\": true }",
    ))
  assert string.contains(message, "api_key")
}

pub fn email_allowlist_test() {
  let c = support.config("/tmp", 1)
  assert config.email_allowed(c, "Alice@ACME.dev")
  assert config.email_allowed(c, "guest@example.com")
  assert !config.email_allowed(c, "mallory@example.com")
  assert !config.email_allowed(c, "alice@sub.acme.dev")
  assert !config.email_allowed(c, "@acme.dev")
  let wildcard =
    config.Config(
      ..c,
      auth: config.Auth(..c.auth, allowed_domains: ["*.acme.dev"]),
    )
  assert config.email_allowed(wildcard, "alice@sub.acme.dev")
  assert !config.email_allowed(wildcard, "alice@evilacme.dev")
}

pub fn example_config_parses_test() {
  support.putenv(
    "HUDDY_SECRET_KEY",
    "example-secret-0123456789abcdef0123456789",
  )
  support.putenv("SMTP_PASSWORD", "pw")
  support.putenv("TYPESAFE_API_KEY", "key")
  let assert Ok(c) = config.load("huddy.example.json")
  assert c.team_name == "Acme Platform"
  assert c.email.transport
    == config.Smtp("smtp.acme.dev", 587, "starttls", "huddy", "pw")
  assert c.decision_model.api_key == "key"
  assert c.display.cap_decisions == 2
  assert c.trusted_proxies != []
}

pub fn email_syntax_blocks_header_injection_test() {
  let c = support.config("/tmp", 1)
  assert !config.email_allowed(c, "a\r\nbcc: x@acme.dev")
  assert !config.email_allowed(c, "a b@acme.dev")
  assert !config.email_allowed(c, "a@b@acme.dev")
  assert !config.email_allowed(c, "\"x\"<a@acme.dev")
  assert config.email_allowed(c, "first.last+tag@acme.dev")
}

pub fn invalid_trusted_proxy_is_an_error_test() {
  let text =
    string.replace(
      minimal,
      "\"secret_key\"",
      "\"server\": { \"trusted_proxies\": [\"not-an-ip\"] }, \"secret_key\"",
    )
  let assert Error(message) = parse(text)
  assert string.contains(message, "trusted_proxies")
}

pub fn decision_model_endpoint_test() {
  let assert Ok(c) = parse(minimal)
  assert c.decision_model.endpoint == "https://api.typesafe.ai/v1/systemone"
  let openrouter =
    string.replace(
      minimal,
      "{ \"enabled\": false }",
      "{ \"enabled\": false, \"endpoint\": \"https://openrouter.ai/api/alpha/decisions\", \"model\": \"typesafe/jev-1.13\" }",
    )
  let assert Ok(c) = parse(openrouter)
  assert c.decision_model.endpoint
    == "https://openrouter.ai/api/alpha/decisions"
  assert c.decision_model.model == "typesafe/jev-1.13"
}

pub fn compose_config_parses_test() {
  support.putenv(
    "HUDDY_SECRET_KEY",
    "compose-secret-0123456789abcdefghijklmnop",
  )
  support.putenv("DECISION_MODEL_API_KEY", "key")
  support.putenv("HUDDY_ALLOWED_DOMAIN", "example.com")
  support.putenv("SMTP_HOST", "mailpit")
  let assert Ok(c) = config.load("deploy/huddy.compose.json")
  assert c.auth.allowed_domains == ["example.com"]
  assert c.email.transport == config.Smtp("mailpit", 1025, "none", "", "")
}
