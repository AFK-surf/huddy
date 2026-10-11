//// Huddy as an OAuth 2.1 authorization server for its own MCP endpoint
//// (§10.2): metadata, authorize + consent, token (PKCE, rotating refresh
//// tokens), dynamic client registration, and revocation. Tokens are opaque
//// random strings stored as SHA-256 hashes.

import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import huddy/config
import huddy/ctx.{type Ctx}
import huddy/ephemeral.{type AuthRequest, AuthRequest, Ephemeral, OAuthCode}
import huddy/model.{type OAuthClient, OAuthClient, OAuthToken}
import huddy/state
import huddy/store
import huddy/sys
import huddy/web/html
import huddy/web/layout
import huddy/web/session
import logging
import wisp.{type Request, type Response}

pub const scopes = ["huddy:read", "huddy:write"]

// --- metadata -----------------------------------------------------------------

pub fn protected_resource_metadata_url(ctx: Ctx) -> String {
  ctx.config.base_url <> "/.well-known/oauth-protected-resource/mcp"
}

fn json_response(body: json.Json, status: Int) -> Response {
  wisp.json_response(json.to_string(body), status)
  |> wisp.set_header("cache-control", "no-store")
  |> wisp.set_header("access-control-allow-origin", "*")
}

pub fn protected_resource(ctx: Ctx) -> Response {
  json_response(
    json.object([
      #("resource", json.string(config.mcp_resource(ctx.config))),
      #("authorization_servers", json.array([ctx.config.base_url], json.string)),
      #("scopes_supported", json.array(scopes, json.string)),
      #("bearer_methods_supported", json.array(["header"], json.string)),
      #("resource_name", json.string("Huddy · " <> ctx.config.team_name)),
    ]),
    200,
  )
}

pub fn authorization_server(ctx: Ctx) -> Response {
  let base = ctx.config.base_url
  let mcp = ctx.config.mcp
  json_response(
    json.object(
      list.flatten([
        [
          #("issuer", json.string(base)),
          #("authorization_endpoint", json.string(base <> "/oauth/authorize")),
          #("token_endpoint", json.string(base <> "/oauth/token")),
          #("revocation_endpoint", json.string(base <> "/oauth/revoke")),
          #("scopes_supported", json.array(scopes, json.string)),
          #("response_types_supported", json.array(["code"], json.string)),
          #(
            "grant_types_supported",
            json.array(["authorization_code", "refresh_token"], json.string),
          ),
          #(
            "token_endpoint_auth_methods_supported",
            json.array(["none"], json.string),
          ),
          #(
            "revocation_endpoint_auth_methods_supported",
            json.array(["none"], json.string),
          ),
          #(
            "code_challenge_methods_supported",
            json.array(["S256"], json.string),
          ),
          #(
            "client_id_metadata_document_supported",
            json.bool(mcp.client_id_metadata_documents),
          ),
          #("authorization_response_iss_parameter_supported", json.bool(True)),
        ],
        case mcp.dynamic_client_registration {
          True -> [
            #("registration_endpoint", json.string(base <> "/oauth/register")),
          ]
          False -> []
        },
      ]),
    ),
    200,
  )
}

// --- helpers -------------------------------------------------------------------

/// PKCE S256: BASE64URL(SHA256(verifier)) == challenge.
pub fn pkce_ok(verifier: String, challenge: String) -> Bool {
  let computed =
    crypto.hash(crypto.Sha256, bit_array.from_string(verifier))
    |> bit_array.base64_url_encode(False)
  string.length(verifier) >= 43
  && string.length(verifier) <= 128
  && sys.secure_equal(computed, challenge)
}

fn is_loopback(host: String) -> Bool {
  host == "127.0.0.1" || host == "[::1]" || host == "::1" || host == "localhost"
}

/// Exact match, except that loopback redirect URIs may use any port
/// (RFC 8252 §7.3).
pub fn redirect_matches(registered: String, requested: String) -> Bool {
  case registered == requested {
    True -> True
    False ->
      case uri.parse(registered), uri.parse(requested) {
        Ok(a), Ok(b) ->
          a.scheme == Some("http")
          && b.scheme == Some("http")
          && a.host == b.host
          && option.map(a.host, is_loopback) == Some(True)
          && a.path == b.path
          && a.query == b.query
        _, _ -> False
      }
  }
}

fn redirect_host(redirect_uri: String) -> String {
  case uri.parse(redirect_uri) {
    Ok(u) -> option.unwrap(u.host, redirect_uri)
    Error(_) -> redirect_uri
  }
}

fn valid_redirect_uri(u: String) -> Bool {
  case uri.parse(u) {
    Ok(parsed) ->
      case parsed.scheme, parsed.host, parsed.fragment {
        Some("https"), Some(_), None -> True
        Some("http"), Some(host), None -> is_loopback(host)
        // private-use URI schemes for native apps (RFC 8252 §7.1)
        Some(scheme), _, None ->
          !list.contains(
            ["http", "https", "javascript", "data", "file", "vbscript"],
            scheme,
          )
        _, _, _ -> False
      }
    Error(_) -> False
  }
}

/// Normalize a requested scope string; empty means everything.
pub fn normalize_scope(requested: String) -> Result(String, Nil) {
  case string.trim(requested) {
    "" -> Ok(string.join(scopes, " "))
    s -> {
      let wanted =
        string.split(s, " ")
        |> list.filter(fn(x) { list.contains(scopes, x) })
        |> list.unique
      case wanted {
        [] -> Error(Nil)
        _ ->
          // write implies read for Huddy's tools
          Ok(
            state.merge_scopes(
              string.join(wanted, " "),
              case list.contains(wanted, "huddy:write") {
                True -> "huddy:read"
                False -> ""
              },
            ),
          )
      }
    }
  }
}

fn resource_ok(ctx: Ctx, resource: String) -> Bool {
  let canonical = config.mcp_resource(ctx.config)
  resource == ""
  || resource == canonical
  || resource == ctx.config.base_url
  || resource == canonical <> "/"
}

/// Look up (or fetch, for CIMD) a client.
fn resolve_client(ctx: Ctx, client_id: String) -> Result(OAuthClient, String) {
  let now = sys.now_ms()
  let cached = store.read(ctx.store, fn(s, _) { state.client(s, client_id) })
  case string.starts_with(client_id, "https://") {
    True ->
      case ctx.config.mcp.client_id_metadata_documents {
        False -> Error("this server does not accept URL client_ids")
        True ->
          case cached {
            Some(c) if c.kind == model.Cimd ->
              case option.unwrap(c.cache_until, 0) > now {
                True -> Ok(c)
                False -> refetch(ctx, client_id, now)
              }
            _ -> refetch(ctx, client_id, now)
          }
      }
    False ->
      case cached {
        Some(c) if c.kind == model.Dcr -> Ok(c)
        _ -> Error("unknown client_id")
      }
  }
}

fn refetch(
  ctx: Ctx,
  client_id: String,
  now: Int,
) -> Result(OAuthClient, String) {
  use client <- result.try(ctx.fetch_client(client_id, now))
  let _ =
    store.update(ctx.store, fn(s, e, _) {
      store.Changed(state.put_client(s, client), e, [], Nil)
    })
  Ok(client)
}

fn error_page(ctx: Ctx, message: String) -> Response {
  layout.respond(
    400,
    layout.card_page(ctx, "Authorization failed", [
      html.el("h1", [], [html.text("Can't authorize this client")]),
      layout.error(message),
    ]),
  )
}

fn redirect_with(
  redirect_uri: String,
  params: List(#(String, String)),
) -> Response {
  let sep = case string.contains(redirect_uri, "?") {
    True -> "&"
    False -> "?"
  }
  wisp.redirect(redirect_uri <> sep <> uri.query_to_string(params))
}

// --- authorize ------------------------------------------------------------------

pub fn authorize(ctx: Ctx, req: Request) -> Response {
  case req.method {
    http.Get -> authorize_get(ctx, req)
    http.Post -> authorize_post(ctx, req)
    _ -> wisp.method_not_allowed([http.Get, http.Post])
  }
}

fn authorize_get(ctx: Ctx, req: Request) -> Response {
  // Sign in first: resolving a URL client_id fetches it, which anonymous
  // visitors must not be able to trigger.
  use user <- session.require_user(ctx, req)
  let q = wisp.get_query(req)
  let param = fn(name) { list.key_find(q, name) |> result.unwrap("") }
  let client_id = param("client_id")
  let redirect_uri = param("redirect_uri")
  case resolve_client(ctx, client_id) {
    Error(reason) -> error_page(ctx, reason)
    Ok(client) ->
      case list.any(client.redirect_uris, redirect_matches(_, redirect_uri)) {
        False -> {
          logging.log(
            logging.Warning,
            "oauth authorize: unregistered redirect_uri "
              <> redirect_uri
              <> " for "
              <> client_id,
          )
          error_page(ctx, "redirect_uri is not registered for this client")
        }
        True -> {
          let fail = fn(error, description) {
            redirect_with(redirect_uri, [
              #("error", error),
              #("error_description", description),
              #("state", param("state")),
              #("iss", ctx.config.base_url),
            ])
          }
          case
            param("response_type"),
            param("code_challenge"),
            param("code_challenge_method"),
            normalize_scope(param("scope")),
            resource_ok(ctx, param("resource"))
          {
            r, _, _, _, _ if r != "code" ->
              fail(
                "unsupported_response_type",
                "only response_type=code is supported",
              )
            _, "", _, _, _ ->
              fail("invalid_request", "PKCE code_challenge is required")
            _, _, m, _, _ if m != "S256" ->
              fail("invalid_request", "code_challenge_method must be S256")
            _, _, _, Error(_), _ -> fail("invalid_scope", "unknown scope")
            _, _, _, _, False -> fail("invalid_target", "unknown resource")
            _, challenge, _, Ok(scope), True -> {
              let id = sys.random_token(24)
              let request =
                AuthRequest(
                  user: user.id,
                  client_id:,
                  client_name: client.client_name,
                  redirect_uri:,
                  code_challenge: challenge,
                  state: param("state"),
                  scope:,
                  resource: config.mcp_resource(ctx.config),
                  expires_at: sys.now_ms() + 600_000,
                )
              store.update_lazy(ctx.store, fn(_s, e, _) {
                store.EphemeralChanged(
                  Ephemeral(
                    ..e,
                    auth_requests: dict.insert(e.auth_requests, id, request),
                  ),
                  Nil,
                )
              })
              logging.log(
                logging.Info,
                "oauth authorize: consent shown client_id="
                  <> client_id
                  <> " redirect_uri="
                  <> redirect_uri,
              )
              consent_page(ctx, user, id, request)
            }
          }
        }
      }
  }
}

fn consent_page(
  ctx: Ctx,
  user: model.User,
  id: String,
  r: AuthRequest,
) -> Response {
  let host = redirect_host(r.redirect_uri)
  let localhost_only = is_loopback(host)
  layout.respond(
    200,
    layout.card_page(ctx, "Authorize", [
      html.el("h1", [], [html.text("Connect " <> r.client_name <> "?")]),
      html.el("p", [], [
        html.el("b", [], [html.text(r.client_name)]),
        html.text(" wants to use Huddy as " <> user.email <> "."),
      ]),
      html.el("ul", [html.class("rows")], [
        html.el("li", [], [html.text("Client: " <> r.client_id)]),
        html.el("li", [], [html.text("Sends you back to: " <> host)]),
        html.el("li", [], [
          html.text(case string.contains(r.scope, "huddy:write") {
            True -> "Can read the board and post as your agents"
            False -> "Can read the board"
          }),
        ]),
      ]),
      html.when(localhost_only, fn() {
        layout.notice(
          "This client receives the result on your own machine ("
          <> host
          <> "). Only approve if you just started connecting an agent here.",
        )
      }),
      html.post_form(
        "/oauth/authorize",
        [html.class("row")],
        [#("request", id)],
        [
          layout.button("Approve", [
            #("type", "submit"),
            #("name", "decision"),
            #("value", "approve"),
          ]),
          html.el(
            "button",
            [
              html.class("linkish"),
              #("type", "submit"),
              #("name", "decision"),
              #("value", "deny"),
            ],
            [html.text("Deny")],
          ),
        ],
      ),
    ]),
  )
}

fn authorize_post(ctx: Ctx, req: Request) -> Response {
  use user <- session.require_user(ctx, req)
  case session.same_origin(ctx, req) {
    False -> wisp.bad_request("cross-origin request")
    True -> {
      use form <- wisp.require_form(req)
      let id = session.form_value(form, "request")
      let decision = session.form_value(form, "decision")
      let found =
        store.update_lazy(ctx.store, fn(_s, e, now) {
          case dict.get(e.auth_requests, id) {
            Ok(r) if r.user == user.id && r.expires_at > now ->
              store.EphemeralChanged(
                Ephemeral(..e, auth_requests: dict.delete(e.auth_requests, id)),
                Some(r),
              )
            _ -> store.NoChange(None)
          }
        })
      case found {
        None -> {
          logging.log(
            logging.Warning,
            "oauth authorize: unknown or expired request (decision="
              <> decision
              <> ")",
          )
          error_page(
            ctx,
            "This authorization request has expired. Start again from your agent.",
          )
        }
        Some(r) ->
          case decision {
            "approve" -> {
              let code = sys.random_token(32)
              let issued =
                store.update(ctx.store, fn(s, e, now) {
                  let #(s, _) =
                    state.ensure_grant(s, r.client_id, user.id, r.scope, now)
                  let entry =
                    OAuthCode(
                      user: user.id,
                      client_id: r.client_id,
                      redirect_uri: r.redirect_uri,
                      code_challenge: r.code_challenge,
                      scope: r.scope,
                      resource: r.resource,
                      expires_at: now + 600_000,
                    )
                  store.Changed(
                    s,
                    Ephemeral(
                      ..e,
                      oauth_codes: dict.insert(
                        e.oauth_codes,
                        sys.sha256_hex(code),
                        entry,
                      ),
                    ),
                    [],
                    Nil,
                  )
                })
              case issued {
                Ok(_) -> {
                  logging.log(
                    logging.Info,
                    "oauth authorize: approved client_id="
                      <> r.client_id
                      <> ", redirecting to "
                      <> r.redirect_uri,
                  )
                  redirect_with(r.redirect_uri, [
                    #("code", code),
                    #("state", r.state),
                    #("iss", ctx.config.base_url),
                  ])
                }
                Error(e) -> error_page(ctx, e)
              }
            }
            _ ->
              redirect_with(r.redirect_uri, [
                #("error", "access_denied"),
                #("state", r.state),
                #("iss", ctx.config.base_url),
              ])
          }
      }
    }
  }
}

// --- token ----------------------------------------------------------------------

fn token_error(error: String, description: String) -> Response {
  logging.log(logging.Warning, "oauth: " <> error <> ": " <> description)
  json_response(
    json.object([
      #("error", json.string(error)),
      #("error_description", json.string(description)),
    ]),
    400,
  )
}

pub fn token(ctx: Ctx, req: Request) -> Response {
  logging.log(
    logging.Info,
    "oauth token request: content-type="
      <> result.unwrap(list.key_find(req.headers, "content-type"), "-"),
  )
  use form <- wisp.require_form(req)
  let value = session.form_value(form, _)
  logging.log(
    logging.Info,
    "oauth token: grant_type="
      <> value("grant_type")
      <> " client_id="
      <> value("client_id")
      <> " redirect_uri="
      <> value("redirect_uri")
      <> " resource="
      <> value("resource")
      <> " verifier_len="
      <> int.to_string(string.length(value("code_verifier"))),
  )
  case sys.rate_limit("oauth-ip:" <> session.client_ip(req), 60, 60_000) {
    False -> token_error("slow_down", "too many requests")
    True ->
      case value("grant_type") {
        "authorization_code" -> exchange_code(ctx, value)
        "refresh_token" -> refresh(ctx, value)
        _ ->
          token_error(
            "unsupported_grant_type",
            "use authorization_code or refresh_token",
          )
      }
  }
}

fn issue(
  ctx: Ctx,
  grant_id: Int,
  scope: String,
  resource: String,
  family: Option(String),
) -> Response {
  let access = sys.random_token(32)
  let refresh_token = sys.random_token(32)
  let family = option.unwrap(family, sys.random_token(12))
  let mcp = ctx.config.mcp
  let access_ttl = mcp.access_token_ttl_minutes * 60_000
  let refresh_ttl = mcp.refresh_token_ttl_days * 86_400_000
  let stored =
    store.update(ctx.store, fn(s, e, now) {
      let s =
        s
        |> state.put_token(OAuthToken(
          token_sha256: sys.sha256_hex(access),
          grant: grant_id,
          kind: model.AccessToken,
          family:,
          resource:,
          expires_at: now + access_ttl,
          used_at: None,
        ))
        |> state.put_token(OAuthToken(
          token_sha256: sys.sha256_hex(refresh_token),
          grant: grant_id,
          kind: model.RefreshToken,
          family:,
          resource:,
          expires_at: now + refresh_ttl,
          used_at: None,
        ))
        |> state.touch_grant(grant_id, now)
      store.Changed(s, e, [], Nil)
    })
  case stored {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "oauth: issued tokens for grant " <> int.to_string(grant_id),
      )
      json_response(
        json.object([
          #("access_token", json.string(access)),
          #("token_type", json.string("Bearer")),
          #("expires_in", json.int(access_ttl / 1000)),
          #("refresh_token", json.string(refresh_token)),
          #("scope", json.string(scope)),
        ]),
        200,
      )
    }
    Error(e) ->
      json_response(
        json.object([
          #("error", json.string("server_error")),
          #("error_description", json.string(e)),
        ]),
        500,
      )
  }
}

fn exchange_code(ctx: Ctx, value: fn(String) -> String) -> Response {
  let code_sha = sys.sha256_hex(value("code"))
  let entry =
    store.update_lazy(ctx.store, fn(_s, e, now) {
      case dict.get(e.oauth_codes, code_sha) {
        // single use: removed whether or not the rest checks out
        Ok(c) ->
          store.EphemeralChanged(
            Ephemeral(..e, oauth_codes: dict.delete(e.oauth_codes, code_sha)),
            case c.expires_at > now {
              True -> Some(c)
              False -> None
            },
          )
        Error(_) -> store.NoChange(None)
      }
    })
  case entry {
    None -> token_error("invalid_grant", "unknown, used or expired code")
    Some(c) ->
      case
        c.client_id == value("client_id"),
        c.redirect_uri == value("redirect_uri"),
        pkce_ok(value("code_verifier"), c.code_challenge),
        resource_ok(ctx, value("resource"))
      {
        False, _, _, _ -> token_error("invalid_grant", "client_id mismatch")
        _, False, _, _ -> token_error("invalid_grant", "redirect_uri mismatch")
        _, _, False, _ ->
          token_error("invalid_grant", "PKCE verification failed")
        _, _, _, False -> token_error("invalid_target", "unknown resource")
        True, True, True, True -> {
          let grant =
            store.read(ctx.store, fn(s, _) {
              dict.values(s.oauth_grants)
              |> list.find(fn(g) {
                g.client_id == c.client_id
                && g.user == c.user
                && g.revoked_at == None
              })
            })
          case grant {
            Ok(g) -> issue(ctx, g.id, c.scope, c.resource, None)
            Error(_) -> token_error("invalid_grant", "the grant was revoked")
          }
        }
      }
  }
}

type Refresh {
  Rotate(grant: Int, scope: String, resource: String, family: String)
  Reused
  Invalid
}

fn refresh(ctx: Ctx, value: fn(String) -> String) -> Response {
  let sha = sys.sha256_hex(value("refresh_token"))
  let client_id = value("client_id")
  let outcome =
    store.update(ctx.store, fn(s, e, now) {
      case state.token(s, sha) {
        Some(t) if t.kind == model.RefreshToken ->
          case t.used_at, state.grant(s, t.grant) {
            // reuse of a rotated refresh token: revoke the whole family
            Some(_), _ ->
              store.Changed(state.revoke_family(s, t.family), e, [], Reused)
            None, Some(g) if g.revoked_at == None && t.expires_at > now ->
              case client_id == "" || client_id == g.client_id {
                True ->
                  store.Changed(
                    state.mark_token_used(s, sha, now),
                    e,
                    [],
                    Rotate(g.id, g.scope, t.resource, t.family),
                  )
                False -> store.NoChange(Invalid)
              }
            _, _ -> store.NoChange(Invalid)
          }
        _ -> store.NoChange(Invalid)
      }
    })
  case outcome {
    Ok(Rotate(grant, scope, resource, family)) ->
      issue(ctx, grant, scope, resource, Some(family))
    Ok(Reused) ->
      token_error(
        "invalid_grant",
        "refresh token reuse detected; sign in again",
      )
    Ok(Invalid) ->
      token_error("invalid_grant", "unknown or expired refresh token")
    Error(e) ->
      json_response(
        json.object([
          #("error", json.string("server_error")),
          #("error_description", json.string(e)),
        ]),
        500,
      )
  }
}

// --- registration & revocation --------------------------------------------------

pub fn register(ctx: Ctx, req: Request) -> Response {
  case ctx.config.mcp.dynamic_client_registration {
    False -> wisp.not_found()
    True ->
      case
        sys.rate_limit(
          "oauth-register:" <> session.client_ip(req),
          20,
          3_600_000,
        )
      {
        False -> token_error("slow_down", "too many registrations")
        True -> {
          use body <- wisp.require_json(req)
          let decoder = {
            use redirect_uris <- decode.field(
              "redirect_uris",
              decode.list(decode.string),
            )
            use client_name <- decode.optional_field(
              "client_name",
              "MCP client",
              decode.string,
            )
            use method <- decode.optional_field(
              "token_endpoint_auth_method",
              "none",
              decode.string,
            )
            decode.success(#(redirect_uris, client_name, method))
          }
          case decode.run(body, decoder) {
            Error(_) ->
              registration_error(
                "invalid_client_metadata",
                "redirect_uris is required",
              )
            Ok(#(uris, name, method)) ->
              case uris != [] && list.all(uris, valid_redirect_uri), method {
                False, _ ->
                  registration_error(
                    "invalid_redirect_uri",
                    "redirect URIs must be https or http on a loopback address",
                  )
                True, "none" -> {
                  let client_id = "dcr_" <> sys.random_token(18)
                  let now = sys.now_ms()
                  let client =
                    OAuthClient(
                      client_id:,
                      kind: model.Dcr,
                      client_name: string.slice(name, 0, 80),
                      redirect_uris: uris,
                      metadata: "{}",
                      fetched_at: None,
                      cache_until: None,
                      created_at: now,
                    )
                  let _ =
                    store.update(ctx.store, fn(s, e, _) {
                      store.Changed(state.put_client(s, client), e, [], Nil)
                    })
                  logging.log(
                    logging.Info,
                    "oauth register: "
                      <> client_id
                      <> " ("
                      <> client.client_name
                      <> ") redirect_uris="
                      <> string.join(uris, ","),
                  )
                  json_response(
                    json.object([
                      #("client_id", json.string(client_id)),
                      #("client_id_issued_at", json.int(now / 1000)),
                      #("client_name", json.string(client.client_name)),
                      #("redirect_uris", json.array(uris, json.string)),
                      #(
                        "grant_types",
                        json.array(
                          ["authorization_code", "refresh_token"],
                          json.string,
                        ),
                      ),
                      #("response_types", json.array(["code"], json.string)),
                      #("token_endpoint_auth_method", json.string("none")),
                    ]),
                    201,
                  )
                }
                True, _ ->
                  registration_error(
                    "invalid_client_metadata",
                    "only public clients (token_endpoint_auth_method=none) are supported",
                  )
              }
          }
        }
      }
  }
}

fn registration_error(error: String, description: String) -> Response {
  token_error(error, description)
}

pub fn revoke(ctx: Ctx, req: Request) -> Response {
  use form <- wisp.require_form(req)
  let sha = sys.sha256_hex(session.form_value(form, "token"))
  let _ =
    store.update(ctx.store, fn(s, e, _) {
      case state.token(s, sha) {
        Some(t) ->
          case t.kind {
            model.RefreshToken ->
              store.Changed(state.revoke_family(s, t.family), e, [], Nil)
            model.AccessToken ->
              store.Changed(state.delete_token(s, sha), e, [], Nil)
          }
        None -> store.NoChange(Nil)
      }
    })
  wisp.ok()
}

/// Validate a bearer token for the MCP endpoint: returns the user id and
/// granted scope.
pub fn authenticate(
  ctx: Ctx,
  token: String,
) -> Option(#(model.User, String, Int)) {
  let sha = sys.sha256_hex(token)
  let now = sys.now_ms()
  let found =
    store.read(ctx.store, fn(s, _) {
      case state.valid_token(s, sha, model.AccessToken, now) {
        Some(#(t, g)) ->
          case t.resource == config.mcp_resource(ctx.config) {
            True ->
              state.user(s, g.user)
              |> option.map(fn(u) { #(u, g.scope, g.id) })
            False -> None
          }
        None -> None
      }
    })
  case found {
    Some(#(user, scope, grant_id)) ->
      case config.email_allowed(ctx.config, user.email) {
        True -> {
          store.update_lazy(ctx.store, fn(s, e, now) {
            store.Changed(state.touch_grant(s, grant_id, now), e, [], Nil)
          })
          Some(#(user, scope, grant_id))
        }
        False -> None
      }
    None -> None
  }
}
