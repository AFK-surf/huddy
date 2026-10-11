//// The MCP endpoint over Streamable HTTP (§7.1), dual-era:
//// - modern (2026-07-28): stateless, per-request `_meta`, `server/discover`;
//// - legacy (2025-11-25 and earlier): `initialize` handshake, with the
////   client's name cached by `Mcp-Session-Id`.
//// Responses are always single `application/json` objects; Huddy never
//// opens SSE streams here (GET → 405).

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import huddy/config
import huddy/ctx.{type Ctx}
import huddy/ephemeral.{Ephemeral, McpSession}
import huddy/mcp/tools.{type Principal, Principal}
import huddy/oauth/server as oauth
import huddy/rank
import huddy/state
import huddy/store
import huddy/sys
import logging
import mist

pub const modern_version = "2026-07-28"

pub const legacy_versions = [
  "2025-11-25",
  "2025-06-18",
  "2025-03-26",
  "2024-11-05",
]

const meta_version = "io.modelcontextprotocol/protocolVersion"

const meta_client = "io.modelcontextprotocol/clientInfo"

pub type Auth {
  Bearer
  Secret(String)
}

type Id {
  IntId(Int)
  StrId(String)
  NoId
}

type Rpc {
  Rpc(id: Id, method: String, params: Dynamic)
}

fn id_json(id: Id) -> Json {
  case id {
    IntId(n) -> json.int(n)
    StrId(s) -> json.string(s)
    NoId -> json.null()
  }
}

fn respond(
  status: Int,
  body: Json,
  headers: List(#(String, String)),
) -> Response(mist.ResponseData) {
  list.fold(
    headers,
    response.new(status)
      |> response.set_header("content-type", "application/json")
      |> response.set_header("cache-control", "no-store"),
    fn(r, h) { response.set_header(r, h.0, h.1) },
  )
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}

fn empty(
  status: Int,
  headers: List(#(String, String)),
) -> Response(mist.ResponseData) {
  list.fold(headers, response.new(status), fn(r, h) {
    response.set_header(r, h.0, h.1)
  })
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn rpc_error(id: Id, code: Int, message: String, data: Option(Json)) -> Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_json(id)),
    #(
      "error",
      json.object(
        list.flatten([
          [#("code", json.int(code)), #("message", json.string(message))],
          case data {
            Some(d) -> [#("data", d)]
            None -> []
          },
        ]),
      ),
    ),
  ])
}

fn rpc_result(id: Id, result: Json) -> Json {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_json(id)),
    #("result", result),
  ])
}

fn server_info() -> Json {
  json.object([
    #("name", json.string("huddy")),
    #("title", json.string("Huddy")),
    #("version", json.string("0.1.0")),
  ])
}

fn capabilities() -> Json {
  json.object([
    #("tools", json.object([#("listChanged", json.bool(False))])),
    #("resources", json.object([])),
    #("prompts", json.object([])),
  ])
}

fn header(req: Request(a), name: String) -> Option(String) {
  request.get_header(req, name) |> option.from_result
}

/// Decode the `=?base64?…?=` sentinel used in Mcp-Name headers.
fn decode_header_value(value: String) -> String {
  case string.starts_with(value, "=?base64?") && string.ends_with(value, "?=") {
    True ->
      value
      |> string.drop_start(9)
      |> string.drop_end(2)
      |> bit_array.base64_decode
      |> result.try(bit_array.to_string)
      |> result.unwrap(value)
    False -> value
  }
}

pub fn handle(
  ctx: Ctx,
  req: Request(mist.Connection),
  auth: Auth,
) -> Response(mist.ResponseData) {
  // DNS-rebinding protection: a present Origin must be our own.
  let origin_ok = case header(req, "origin") {
    None -> True
    Some(o) -> config.origin_of(o) == config.origin_of(ctx.config.base_url)
  }
  case origin_ok, req.method {
    False, _ ->
      respond(403, rpc_error(NoId, -32_600, "Forbidden origin", None), [])
    True, http.Post -> post(ctx, req, auth)
    True, http.Options -> empty(204, [#("allow", "POST")])
    True, _ -> empty(405, [#("allow", "POST")])
  }
}

fn challenge(ctx: Ctx, extra: String) -> #(String, String) {
  #(
    "www-authenticate",
    "Bearer resource_metadata=\""
      <> oauth.protected_resource_metadata_url(ctx)
      <> "\", scope=\"huddy:read huddy:write\""
      <> extra,
  )
}

fn authenticate(
  ctx: Ctx,
  req: Request(a),
  auth: Auth,
) -> Result(Principal, Response(mist.ResponseData)) {
  case auth {
    Secret(secret) -> {
      let sha = sys.sha256_hex(secret)
      let found =
        store.read(ctx.store, fn(s, _) {
          state.link_by_secret(s, sha)
          |> option.then(fn(l) {
            state.user(s, l.user) |> option.map(fn(u) { #(l, u) })
          })
        })
      case ctx.config.mcp.secret_urls, found {
        True, Some(#(link, user)) ->
          case config.email_allowed(ctx.config, user.email) {
            True -> {
              store.update_lazy(ctx.store, fn(s, e, now) {
                store.Changed(state.touch_link(s, link.id, now), e, [], Nil)
              })
              Ok(Principal(user:, scope: link.scope, link: Some(link)))
            }
            False -> Error(empty(404, []))
          }
        _, _ -> Error(empty(404, []))
      }
    }
    Bearer ->
      case header(req, "authorization") {
        Some(value) ->
          case string.split_once(value, " ") {
            Ok(#(scheme, token)) ->
              case string.lowercase(scheme) == "bearer" {
                True ->
                  case oauth.authenticate(ctx, string.trim(token)) {
                    Some(#(user, scope, _)) ->
                      Ok(Principal(user:, scope:, link: None))
                    None ->
                      Error(
                        respond(
                          401,
                          rpc_error(
                            NoId,
                            -32_001,
                            "invalid or expired token",
                            None,
                          ),
                          [challenge(ctx, ", error=\"invalid_token\"")],
                        ),
                      )
                  }
                False ->
                  Error(
                    respond(
                      401,
                      rpc_error(NoId, -32_001, "bearer token required", None),
                      [challenge(ctx, "")],
                    ),
                  )
              }
            Error(_) ->
              Error(
                respond(
                  401,
                  rpc_error(NoId, -32_001, "bearer token required", None),
                  [challenge(ctx, "")],
                ),
              )
          }
        None ->
          Error(
            respond(
              401,
              rpc_error(NoId, -32_001, "authorization required", None),
              [challenge(ctx, "")],
            ),
          )
      }
  }
}

fn parse(body: BitArray) -> Result(Rpc, Nil) {
  let decoder = {
    use id <- decode.optional_field(
      "id",
      NoId,
      decode.one_of(decode.int |> decode.map(IntId), [
        decode.string |> decode.map(StrId),
      ]),
    )
    use method <- decode.field("method", decode.string)
    use params <- decode.optional_field(
      "params",
      dynamic.properties([]),
      decode.dynamic,
    )
    decode.success(Rpc(id:, method:, params:))
  }
  json.parse_bits(body, decoder) |> result.replace_error(Nil)
}

fn meta_string(params: Dynamic, key: String) -> Option(String) {
  decode.run(params, decode.at(["_meta", key], decode.string))
  |> option.from_result
}

fn modern_client_name(params: Dynamic) -> Option(String) {
  decode.run(params, decode.at(["_meta", meta_client, "name"], decode.string))
  |> option.from_result
}

fn param_string(params: Dynamic, key: String) -> Option(String) {
  decode.run(params, decode.at([key], decode.string)) |> option.from_result
}

fn post(
  ctx: Ctx,
  req: Request(mist.Connection),
  auth: Auth,
) -> Response(mist.ResponseData) {
  // Authenticate (headers and path only) before reading the body: the body
  // limit is large, since documents can be uploaded as base64 in a tool call.
  let limit =
    int.max(1_048_576, ctx.config.limits.document_max_mb * 1_400_000 + 65_536)
  case authenticate(ctx, req, auth) {
    Error(resp) -> resp
    Ok(principal) ->
      case mist.read_body(req, limit) {
        Error(_) ->
          respond(
            413,
            rpc_error(
              NoId,
              -32_600,
              "request body too large or unreadable",
              None,
            ),
            [],
          )
        Ok(req) ->
          case parse(req.body) {
            Error(_) ->
              respond(
                400,
                rpc_error(
                  NoId,
                  -32_700,
                  "parse error: expected one JSON-RPC message",
                  None,
                ),
                [],
              )
            Ok(rpc) ->
              case rpc.id, meta_string(rpc.params, meta_version) {
                // notifications (no id) are accepted and ignored
                NoId, _ -> empty(202, [])
                _, Some(version) -> modern(ctx, req, principal, rpc, version)
                _, None -> legacy(ctx, req, principal, rpc)
              }
          }
      }
  }
}

// --- modern ---------------------------------------------------------------------

fn modern(
  ctx: Ctx,
  req: Request(a),
  principal: Principal,
  rpc: Rpc,
  version: String,
) -> Response(mist.ResponseData) {
  let mismatch = fn(message) {
    respond(
      400,
      rpc_error(rpc.id, -32_020, "Header mismatch: " <> message, None),
      [],
    )
  }
  case version == modern_version {
    False ->
      respond(
        400,
        rpc_error(
          rpc.id,
          -32_022,
          "Unsupported protocol version",
          Some(
            json.object([
              #(
                "supported",
                json.array([modern_version, ..legacy_versions], json.string),
              ),
              #("requested", json.string(version)),
            ]),
          ),
        ),
        [],
      )
    True -> {
      let name_source = case rpc.method {
        "tools/call" | "prompts/get" ->
          Some(param_string(rpc.params, "name") |> option.unwrap(""))
        "resources/read" ->
          Some(param_string(rpc.params, "uri") |> option.unwrap(""))
        _ -> None
      }
      let method = rpc.method
      case
        header(req, "mcp-protocol-version"),
        header(req, "mcp-method"),
        name_source
      {
        h, _, _ if h != Some(version) ->
          mismatch("MCP-Protocol-Version must equal the _meta protocol version")
        _, m, _ if m != Some(method) ->
          mismatch("Mcp-Method must equal the request method")
        _, _, Some(expected) ->
          case
            option.map(header(req, "mcp-name"), decode_header_value)
            == Some(expected)
          {
            True ->
              dispatch(
                ctx,
                principal,
                rpc,
                modern_client_name(rpc.params),
                True,
              )
            False -> mismatch("Mcp-Name must equal params.name / params.uri")
          }
        _, _, None ->
          dispatch(ctx, principal, rpc, modern_client_name(rpc.params), True)
      }
    }
  }
}

// --- legacy ---------------------------------------------------------------------

fn legacy(
  ctx: Ctx,
  req: Request(a),
  principal: Principal,
  rpc: Rpc,
) -> Response(mist.ResponseData) {
  case rpc.method {
    "initialize" -> initialize(ctx, rpc)
    _ -> {
      let header_ok = case header(req, "mcp-protocol-version") {
        None -> True
        Some(v) -> list.contains([modern_version, ..legacy_versions], v)
      }
      case header_ok {
        False ->
          respond(
            400,
            rpc_error(rpc.id, -32_600, "Unsupported MCP-Protocol-Version", None),
            [],
          )
        True -> {
          let client_name = case header(req, "mcp-session-id") {
            Some(sid) ->
              store.read(ctx.store, fn(_, e) {
                dict.get(e.mcp_sessions, sid)
                |> result.map(fn(s) { s.client_name })
                |> option.from_result
              })
            None -> None
          }
          dispatch(ctx, principal, rpc, client_name, False)
        }
      }
    }
  }
}

fn initialize(ctx: Ctx, rpc: Rpc) -> Response(mist.ResponseData) {
  let requested =
    param_string(rpc.params, "protocolVersion") |> option.unwrap("")
  let version = case list.contains(legacy_versions, requested) {
    True -> requested
    False -> "2025-11-25"
  }
  let client_name =
    decode.run(rpc.params, decode.at(["clientInfo", "name"], decode.string))
    |> result.unwrap("")
  let sid = sys.random_token(24)
  store.update_lazy(ctx.store, fn(_s, e, now) {
    store.EphemeralChanged(
      Ephemeral(
        ..e,
        mcp_sessions: dict.insert(
          e.mcp_sessions,
          sid,
          McpSession(
            client_name:,
            protocol_version: version,
            expires_at: now + 86_400_000,
          ),
        ),
      ),
      Nil,
    )
  })
  respond(
    200,
    rpc_result(
      rpc.id,
      json.object([
        #("protocolVersion", json.string(version)),
        #("capabilities", capabilities()),
        #("serverInfo", server_info()),
        #("instructions", json.string(tools.instructions(ctx))),
      ]),
    ),
    [#("mcp-session-id", sid)],
  )
}

// --- methods --------------------------------------------------------------------

fn dispatch(
  ctx: Ctx,
  principal: Principal,
  rpc: Rpc,
  client_name: Option(String),
  is_modern: Bool,
) -> Response(mist.ResponseData) {
  let ok = fn(fields: List(#(String, Json))) {
    let fields = case is_modern {
      True ->
        list.append(fields, [
          #("resultType", json.string("complete")),
          #(
            "_meta",
            json.object([#("io.modelcontextprotocol/serverInfo", server_info())]),
          ),
        ])
      False -> fields
    }
    respond(200, rpc_result(rpc.id, json.object(fields)), [])
  }
  let cacheable = [
    #("ttlMs", json.int(60_000)),
    #("cacheScope", json.string("private")),
  ]
  let not_found = fn() {
    respond(
      case is_modern {
        True -> 404
        False -> 200
      },
      rpc_error(rpc.id, -32_601, "Method not found: " <> rpc.method, None),
      [],
    )
  }
  case rpc.method {
    "server/discover" ->
      ok(list.append(
        [
          #(
            "supportedVersions",
            json.array([modern_version, ..legacy_versions], json.string),
          ),
          #("capabilities", capabilities()),
          #("instructions", json.string(tools.instructions(ctx))),
        ],
        cacheable,
      ))
    "ping" -> ok([])
    "logging/setLevel" -> ok([])
    "tools/list" ->
      ok([
        #("tools", json.preprocessed_array(tools.definitions(ctx, principal))),
        ..cacheable
      ])
    "tools/call" -> {
      let name = param_string(rpc.params, "name") |> option.unwrap("")
      let args =
        decode.run(rpc.params, decode.at(["arguments"], decode.dynamic))
        |> result.unwrap(dynamic.properties([]))
      let needs_write = list.contains(tools.write_tools, name)
      case needs_write && !string.contains(principal.scope, "huddy:write") {
        True ->
          case principal.link {
            None ->
              respond(
                403,
                rpc_error(
                  rpc.id,
                  -32_003,
                  "insufficient scope: huddy:write required",
                  None,
                ),
                [
                  #(
                    "www-authenticate",
                    "Bearer error=\"insufficient_scope\", scope=\"huddy:read huddy:write\", resource_metadata=\""
                      <> oauth.protected_resource_metadata_url(ctx)
                      <> "\", error_description=\"Posting to Huddy needs the huddy:write scope\"",
                  ),
                ],
              )
            Some(_) ->
              ok([
                #(
                  "content",
                  json.array(
                    [
                      text_content(
                        "This Huddy URL is read-only; create a read + write URL in Huddy's settings to post.",
                      ),
                    ],
                    fn(x) { x },
                  ),
                ),
                #("isError", json.bool(True)),
              ])
          }
        False -> {
          let result = tools.call(ctx, principal, client_name, name, args)
          log_tool(principal, name, result.is_error)
          ok([
            #(
              "content",
              json.preprocessed_array([
                text_content(result.text),
                ..result.extra
              ]),
            ),
            #("structuredContent", result.structured),
            #("isError", json.bool(result.is_error)),
          ])
        }
      }
    }
    "resources/list" ->
      ok([
        #(
          "resources",
          json.preprocessed_array([
            json.object([
              #("uri", json.string("huddy://display")),
              #("name", json.string("display")),
              #("title", json.string("Huddy display")),
              #(
                "description",
                json.string("The board exactly as humans see it."),
              ),
              #("mimeType", json.string("text/plain")),
            ]),
          ]),
        ),
        ..cacheable
      ])
    "resources/templates/list" ->
      ok([
        #(
          "resourceTemplates",
          json.preprocessed_array([
            json.object([
              #(
                "uriTemplate",
                json.string("huddy://agents/{owner}/{name}/{project}"),
              ),
              #("name", json.string("agent")),
              #("title", json.string("One agent's items")),
              #(
                "description",
                json.string(
                  "An agent's goal, open tasks and decisions, by owner handle, agent name and project.",
                ),
              ),
              #("mimeType", json.string("text/plain")),
            ]),
          ]),
        ),
        ..cacheable
      ])
    "resources/read" -> {
      let uri = param_string(rpc.params, "uri") |> option.unwrap("")
      let filters = case string.split(uri, "/") {
        ["huddy:", "", "display"] -> Ok(#(False, rank.no_filters()))
        ["huddy:", "", "agents", owner, name, project] ->
          Ok(#(True, rank.Filters(Some(owner), Some(project), Some(name), None)))
        _ -> Error(Nil)
      }
      case filters {
        Ok(#(all, f)) -> {
          let #(text, _) = tools.board_text(ctx, all, f, False)
          ok([
            #(
              "contents",
              json.preprocessed_array([
                json.object([
                  #("uri", json.string(uri)),
                  #("mimeType", json.string("text/plain")),
                  #("text", json.string(text)),
                ]),
              ]),
            ),
            ..cacheable
          ])
        }
        Error(_) ->
          respond(
            200,
            rpc_error(rpc.id, -32_602, "Resource not found: " <> uri, None),
            [],
          )
      }
    }
    "prompts/list" ->
      ok([
        #(
          "prompts",
          json.preprocessed_array([
            json.object([
              #("name", json.string("huddy-protocol")),
              #("title", json.string("How to report to Huddy")),
              #(
                "description",
                json.string(
                  "The reporting protocol for agents on this Huddy board.",
                ),
              ),
            ]),
          ]),
        ),
        ..cacheable
      ])
    "prompts/get" ->
      case param_string(rpc.params, "name") {
        Some("huddy-protocol") ->
          ok([
            #("description", json.string("How to report to Huddy")),
            #(
              "messages",
              json.preprocessed_array([
                json.object([
                  #("role", json.string("user")),
                  #("content", text_content(tools.instructions(ctx))),
                ]),
              ]),
            ),
          ])
        _ ->
          respond(200, rpc_error(rpc.id, -32_602, "Unknown prompt", None), [])
      }
    _ -> not_found()
  }
}

fn text_content(text: String) -> Json {
  json.object([#("type", json.string("text")), #("text", json.string(text))])
}

fn log_tool(principal: Principal, name: String, is_error: Bool) -> Nil {
  logging.log(
    logging.Info,
    "mcp "
      <> name
      <> " by user "
      <> int.to_string(principal.user.id)
      <> case is_error {
      True -> " (tool error)"
      False -> ""
    },
  )
}
