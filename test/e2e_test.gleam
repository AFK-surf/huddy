//// End-to-end: boot the whole app on a local port with a fake decision
//// model and an e-mail recorder, then drive it over HTTP.

import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import huddy
import huddy/ctx.{type Ctx}
import huddy/jev
import huddy/persist
import huddy/state
import huddy/store
import huddy/sys
import support

type Mail {
  Mail(to: String, subject: String, body: String)
}

/// Answers: importance 2, readable, and "same as" the first candidate.
fn fake_ask(_state: json.Json, questions: List(#(String, jev.Question))) {
  let answers =
    list.filter_map(questions, fn(q) {
      case q {
        #("importance", _) ->
          Ok(#("importance", jev.ScoreAnswer(2.0, 0.9, dict.new())))
        #("readable", _) -> Ok(#("readable", jev.NoulAnswer(0.95)))
        #("same_as", jev.Choice(_, [#(first, _), ..])) ->
          Ok(#(
            "same_as",
            jev.ChoiceAnswer(first, 0.95, dict.from_list([#(first, 0.95)])),
          ))
        _ -> Error(Nil)
      }
    })
  Ok(jev.Response(dict.from_list(answers), 100, 5, "{}"))
}

fn boot(port: Int) -> #(Ctx, Subject(Mail)) {
  let dir = support.tmp_dir()
  let mails = process.new_subject()
  let cfg = support.config(dir, port)
  let overrides =
    huddy.Overrides(
      ask: Some(Some(fake_ask)),
      send_email: Some(fn(to, subject, body) {
        process.send(mails, Mail(to, subject, body))
      }),
      fetch_client: Some(fn(_, _) { Error("no CIMD in tests") }),
      static_dir: Some("priv/static"),
    )
  let assert Ok(ctx) = huddy.start(cfg, overrides)
  #(ctx, mails)
}

fn base(ctx: Ctx) -> String {
  ctx.config.base_url
}

fn send(
  method: http.Method,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Response(String) {
  let assert Ok(req) = request.to(url)
  let req =
    list.fold(
      headers,
      req |> request.set_method(method) |> request.set_body(body),
      fn(r, h) { request.set_header(r, h.0, h.1) },
    )
  let assert Ok(resp) =
    httpc.configure() |> httpc.timeout(5000) |> httpc.dispatch(req)
  resp
}

fn header(resp: Response(String), name: String) -> String {
  response.get_header(resp, name) |> result.unwrap("")
}

fn rpc(
  url: String,
  extra: List(#(String, String)),
  payload: json.Json,
) -> Response(String) {
  send(
    http.Post,
    url,
    [#("content-type", "application/json"), ..extra],
    json.to_string(payload),
  )
}

fn call(name: String, args: json.Json) -> json.Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(1)),
    #("method", json.string("tools/call")),
    #(
      "params",
      json.object([#("name", json.string(name)), #("arguments", args)]),
    ),
  ])
}

fn tool_text(resp: Response(String)) -> String {
  let decoder =
    decode.at(
      ["result", "content"],
      decode.list(decode.at(["text"], decode.string)),
    )
  case json.parse(resp.body, decoder) {
    Ok([text, ..]) -> text
    _ -> panic as { "unexpected response: " <> resp.body }
  }
}

/// A user plus a secret MCP URL created directly in the store.
fn user_with_link(
  ctx: Ctx,
  email: String,
  pinned: Option(#(String, String)),
) -> String {
  let secret = sys.random_token(32)
  let assert Ok(_) =
    store.update(ctx.store, fn(s, e, now) {
      let #(s, user) = state.create_user(s, email, now)
      let #(s, _) =
        state.create_link(
          s,
          user.id,
          sys.sha256_hex(secret),
          "test",
          option.map(pinned, fn(p) { p.0 }),
          option.map(pinned, fn(p) { p.1 }),
          "huddy:read huddy:write",
          now,
        )
      store.Changed(s, e, [], Nil)
    })
  base(ctx) <> "/mcp/k/" <> secret
}

pub fn login_flow_test() {
  let #(ctx, mails) = boot(48_301)
  let resp =
    send(
      http.Post,
      base(ctx) <> "/login",
      [#("content-type", "application/x-www-form-urlencoded")],
      "email=alice%40acme.dev&return_to=%2F",
    )
  assert resp.status == 303
  let assert Ok(Mail(to:, subject:, ..)) = process.receive(mails, 2000)
  assert to == "alice@acme.dev"
  let code = string.slice(subject, string.length(subject) - 6, 6)
  // a wrong code first
  let wrong =
    send(
      http.Post,
      base(ctx) <> "/login/verify",
      [#("content-type", "application/x-www-form-urlencoded")],
      "email=alice%40acme.dev&code=000000x&return_to=%2F",
    )
  assert string.contains(wrong.body, "isn&#39;t right")
  let ok =
    send(
      http.Post,
      base(ctx) <> "/login/verify",
      [#("content-type", "application/x-www-form-urlencoded")],
      "email=alice%40acme.dev&code=" <> code <> "&return_to=%2F",
    )
  assert ok.status == 303
  let cookie =
    header(ok, "set-cookie")
    |> string.split(";")
    |> list.first
    |> result.unwrap("")
  assert string.starts_with(cookie, "huddy_session=")
  let board = send(http.Get, base(ctx) <> "/", [#("cookie", cookie)], "")
  assert board.status == 200
  assert string.contains(board.body, "Needs a human")
  // the code is single use
  let again =
    send(
      http.Post,
      base(ctx) <> "/login/verify",
      [#("content-type", "application/x-www-form-urlencoded")],
      "email=alice%40acme.dev&code=" <> code <> "&return_to=%2F",
    )
  assert again.status == 200
  // not on the allowlist: no mail is sent, same response
  let other =
    send(
      http.Post,
      base(ctx) <> "/login",
      [#("content-type", "application/x-www-form-urlencoded")],
      "email=mallory%40evil.example&return_to=%2F",
    )
  assert other.status == 303
  assert process.receive(mails, 300) == Error(Nil)
  // cross-origin POSTs with the cookie are refused
  let csrf =
    send(
      http.Post,
      base(ctx) <> "/settings/notify",
      [
        #("cookie", cookie),
        #("origin", "https://evil.example"),
        #("content-type", "application/x-www-form-urlencoded"),
      ],
      "",
    )
  assert csrf.status == 400
}

pub fn mcp_legacy_and_modern_test() {
  let #(ctx, _) = boot(48_302)
  let alice = user_with_link(ctx, "alice@acme.dev", None)
  let bob = user_with_link(ctx, "bob@acme.dev", Some(#("claude-code", "api")))
  // legacy initialize gives a session that remembers the client name
  let init =
    rpc(
      alice,
      [],
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", json.int(1)),
        #("method", json.string("initialize")),
        #(
          "params",
          json.object([
            #("protocolVersion", json.string("2025-06-18")),
            #("clientInfo", json.object([#("name", json.string("Codex"))])),
          ]),
        ),
      ]),
    )
  assert init.status == 200
  assert string.contains(init.body, "\"protocolVersion\":\"2025-06-18\"")
  let sid = header(init, "mcp-session-id")
  assert sid != ""
  let notification =
    rpc(
      alice,
      [#("mcp-session-id", sid)],
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("method", json.string("notifications/initialized")),
      ]),
    )
  assert notification.status == 202
  let goal =
    rpc(
      alice,
      [#("mcp-session-id", sid)],
      call(
        "huddy_set_goal",
        json.object([
          #("project", json.string("huddy")),
          #("title", json.string("Ship OAuth login")),
        ]),
      ),
    )
  assert string.contains(tool_text(goal), "for alice/codex/huddy")
  let task =
    rpc(
      alice,
      [#("mcp-session-id", sid)],
      call(
        "huddy_post",
        json.object([
          #("project", json.string("huddy")),
          #("kind", json.string("task")),
          #("title", json.string("Deflake OAuth refresh test")),
        ]),
      ),
    )
  assert string.contains(tool_text(task), "Stored task")
  // bob's overlapping task: the fake model says "same as" the first candidate
  let overlap =
    rpc(
      bob,
      [],
      call(
        "huddy_post",
        json.object([
          #("kind", json.string("task")),
          #("title", json.string("Deflake the auth tests")),
        ]),
      ),
    )
  let text = tool_text(overlap)
  assert string.contains(text, "for bob/claude-code/api")
  assert string.contains(text, "[overlap]")
  // alice hears about it in her next call
  let inbox =
    rpc(
      alice,
      [#("mcp-session-id", sid)],
      call("huddy_inbox", json.object([#("project", json.string("huddy"))])),
    )
  assert string.contains(
    tool_text(inbox),
    "[overlap] Your i2 looks like bob/claude-code/api",
  )
  // modern request: per-request _meta, headers must match the body
  let meta =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #(
        "io.modelcontextprotocol/clientInfo",
        json.object([#("name", json.string("codex"))]),
      ),
    ])
  let modern_read =
    rpc(
      alice,
      [
        #("mcp-protocol-version", "2026-07-28"),
        #("mcp-method", "tools/call"),
        #("mcp-name", "huddy_read"),
      ],
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", json.string("r1")),
        #("method", json.string("tools/call")),
        #(
          "params",
          json.object([
            #("name", json.string("huddy_read")),
            #("arguments", json.object([])),
            #("_meta", meta),
          ]),
        ),
      ]),
    )
  assert modern_read.status == 200
  assert string.contains(modern_read.body, "\"resultType\":\"complete\"")
  assert string.contains(tool_text(modern_read), "Deflake OAuth refresh test")
  assert string.contains(tool_text(modern_read), "≈ overlaps")
  let mismatch =
    rpc(
      alice,
      [#("mcp-protocol-version", "2026-07-28"), #("mcp-method", "tools/list")],
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", json.int(2)),
        #("method", json.string("tools/call")),
        #(
          "params",
          json.object([#("name", json.string("huddy_read")), #("_meta", meta)]),
        ),
      ]),
    )
  assert mismatch.status == 400
  assert string.contains(mismatch.body, "-32020")
  let unsupported =
    rpc(
      alice,
      [#("mcp-protocol-version", "2099-01-01"), #("mcp-method", "tools/list")],
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", json.int(3)),
        #("method", json.string("tools/list")),
        #(
          "params",
          json.object([
            #(
              "_meta",
              json.object([
                #(
                  "io.modelcontextprotocol/protocolVersion",
                  json.string("2099-01-01"),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    )
  assert unsupported.status == 400
  assert string.contains(unsupported.body, "-32022")
  // unknown secret: 404, never an OAuth challenge
  let bogus =
    rpc(base(ctx) <> "/mcp/k/nope", [], call("huddy_read", json.object([])))
  assert bogus.status == 404
  // foreign Origin: 403
  let foreign =
    rpc(
      alice,
      [#("origin", "https://evil.example")],
      call("huddy_read", json.object([])),
    )
  assert foreign.status == 403
  // GET on the endpoint: 405
  assert send(http.Get, alice, [], "").status == 405
}

pub fn oauth_flow_test() {
  let #(ctx, _) = boot(48_303)
  let b = base(ctx)
  // unauthenticated: 401 with the protected-resource metadata pointer
  let unauth = rpc(b <> "/mcp", [], call("huddy_read", json.object([])))
  assert unauth.status == 401
  assert string.contains(
    header(unauth, "www-authenticate"),
    "/.well-known/oauth-protected-resource/mcp",
  )
  let prm =
    send(http.Get, b <> "/.well-known/oauth-protected-resource/mcp", [], "")
  assert string.contains(prm.body, "\"resource\":\"" <> b <> "/mcp\"")
  let asm =
    send(http.Get, b <> "/.well-known/oauth-authorization-server", [], "")
  assert string.contains(asm.body, "\"S256\"")
  // dynamic client registration
  let reg =
    send(
      http.Post,
      b <> "/oauth/register",
      [#("content-type", "application/json")],
      "{\"redirect_uris\":[\"http://127.0.0.1/callback\"],\"client_name\":\"Test CLI\"}",
    )
  assert reg.status == 201
  let assert Ok(client_id) =
    json.parse(reg.body, decode.at(["client_id"], decode.string))
  // a signed-in user (session created directly)
  let token = sys.random_token(32)
  let assert Ok(_) =
    store.update(ctx.store, fn(s, e, now) {
      let #(s, user) = state.create_user(s, "alice@acme.dev", now)
      store.Changed(
        state.create_session(
          s,
          sys.sha256_hex(token),
          user.id,
          now,
          3_600_000,
          "test",
        ),
        e,
        [],
        Nil,
      )
    })
  let cookie =
    "huddy_session="
    <> bit_array.base64_encode(bit_array.from_string(token), False)
  let verifier = sys.random_token(48)
  let challenge =
    crypto.hash(crypto.Sha256, bit_array.from_string(verifier))
    |> bit_array.base64_url_encode(False)
  let redirect = "http://127.0.0.1:41234/callback"
  let query =
    uri.query_to_string([
      #("response_type", "code"),
      #("client_id", client_id),
      #("redirect_uri", redirect),
      #("code_challenge", challenge),
      #("code_challenge_method", "S256"),
      #("state", "s1"),
      #("resource", b <> "/mcp"),
    ])
  let consent =
    send(http.Get, b <> "/oauth/authorize?" <> query, [#("cookie", cookie)], "")
  assert consent.status == 200
  assert string.contains(consent.body, "Test CLI")
  let assert [_, rest] = string.split(consent.body, "name=\"request\" value=\"")
  let assert [request_id, ..] = string.split(rest, "\"")
  let approved =
    send(
      http.Post,
      b <> "/oauth/authorize",
      [
        #("cookie", cookie),
        #("origin", b),
        #("content-type", "application/x-www-form-urlencoded"),
      ],
      "request=" <> request_id <> "&decision=approve",
    )
  assert approved.status == 303
  let location = header(approved, "location")
  assert string.starts_with(location, redirect <> "?code=")
  let assert Ok(parsed) = uri.parse(location)
  let assert Ok(params) = uri.parse_query(option.unwrap(parsed.query, ""))
  let assert Ok(code) = list.key_find(params, "code")
  assert list.key_find(params, "iss") == Ok(b)
  let form = fn(pairs) { uri.query_to_string(pairs) }
  let bad_pkce =
    send(
      http.Post,
      b <> "/oauth/token",
      [#("content-type", "application/x-www-form-urlencoded")],
      form([
        #("grant_type", "authorization_code"),
        #("code", code),
        #("redirect_uri", redirect),
        #("client_id", client_id),
        #("code_verifier", verifier <> "x"),
      ]),
    )
  assert bad_pkce.status == 400
  // the failed attempt consumed the code
  let reused =
    send(
      http.Post,
      b <> "/oauth/token",
      [#("content-type", "application/x-www-form-urlencoded")],
      form([
        #("grant_type", "authorization_code"),
        #("code", code),
        #("redirect_uri", redirect),
        #("client_id", client_id),
        #("code_verifier", verifier),
      ]),
    )
  assert reused.status == 400
  // run the flow again properly
  let consent =
    send(http.Get, b <> "/oauth/authorize?" <> query, [#("cookie", cookie)], "")
  let assert [_, rest] = string.split(consent.body, "name=\"request\" value=\"")
  let assert [request_id, ..] = string.split(rest, "\"")
  let approved =
    send(
      http.Post,
      b <> "/oauth/authorize",
      [
        #("cookie", cookie),
        #("origin", b),
        #("content-type", "application/x-www-form-urlencoded"),
      ],
      "request=" <> request_id <> "&decision=approve",
    )
  let assert Ok(parsed) = uri.parse(header(approved, "location"))
  let assert Ok(params) = uri.parse_query(option.unwrap(parsed.query, ""))
  let assert Ok(code) = list.key_find(params, "code")
  let tokens =
    send(
      http.Post,
      b <> "/oauth/token",
      [#("content-type", "application/x-www-form-urlencoded")],
      form([
        #("grant_type", "authorization_code"),
        #("code", code),
        #("redirect_uri", redirect),
        #("client_id", client_id),
        #("code_verifier", verifier),
        #("resource", b <> "/mcp"),
      ]),
    )
  assert tokens.status == 200
  let assert Ok(#(access, refresh)) =
    json.parse(tokens.body, {
      use a <- decode.field("access_token", decode.string)
      use r <- decode.field("refresh_token", decode.string)
      decode.success(#(a, r))
    })
  let read =
    rpc(
      b <> "/mcp",
      [#("authorization", "Bearer " <> access)],
      call("huddy_read", json.object([])),
    )
  assert read.status == 200
  // rotate, then reuse the old refresh token: the family is revoked
  let rotated =
    send(
      http.Post,
      b <> "/oauth/token",
      [#("content-type", "application/x-www-form-urlencoded")],
      form([#("grant_type", "refresh_token"), #("refresh_token", refresh)]),
    )
  assert rotated.status == 200
  let assert Ok(access2) =
    json.parse(rotated.body, decode.at(["access_token"], decode.string))
  let reuse =
    send(
      http.Post,
      b <> "/oauth/token",
      [#("content-type", "application/x-www-form-urlencoded")],
      form([#("grant_type", "refresh_token"), #("refresh_token", refresh)]),
    )
  assert reuse.status == 400
  let after =
    rpc(
      b <> "/mcp",
      [#("authorization", "Bearer " <> access2)],
      call("huddy_read", json.object([])),
    )
  assert after.status == 401
}

pub fn concurrent_writes_are_durable_test() {
  let #(ctx, _) = boot(48_304)
  let link = user_with_link(ctx, "alice@acme.dev", Some(#("codex", "huddy")))
  let done = process.new_subject()
  list.each(list.repeat(Nil, 20) |> list.index_map(fn(_, i) { i }), fn(i) {
    process.spawn(fn() {
      let resp =
        rpc(
          link,
          [],
          call(
            "huddy_post",
            json.object([
              #("kind", json.string("task")),
              #("title", json.string("Parallel task " <> int.to_string(i))),
            ]),
          ),
        )
      process.send(done, string.contains(tool_text(resp), "Stored task"))
    })
  })
  let results =
    list.map(list.repeat(Nil, 20), fn(_) { process.receive(done, 10_000) })
  assert list.all(results, fn(r) { r == Ok(True) })
  // every acknowledged write is in the file on disk
  let assert Ok(on_disk) =
    persist.load(ctx.config.storage.path, ctx.config.storage.backup_dir)
  let titles =
    dict.values(on_disk.items)
    |> list.map(fn(i) { i.title })
    |> list.filter(string.starts_with(_, "Parallel task"))
  assert list.length(titles) == 20
}
