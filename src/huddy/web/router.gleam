//// The top-level HTTP handler. `/events` (SSE) and `/mcp` are handled at the
//// mist level; everything else goes through wisp.

import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/result
import gleam/string
import huddy/ctx.{type Ctx}
import huddy/mcp/transport
import huddy/net
import huddy/oauth/server as oauth
import huddy/web/actions
import huddy/web/layout
import huddy/web/login
import huddy/web/page
import huddy/web/session
import huddy/web/settings
import huddy/web/sse
import mist
import wisp
import wisp/wisp_mist

pub fn handler(
  ctx: Ctx,
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  let web = wisp_mist.handler(handle_web(ctx, _), ctx.config.secret_key)
  fn(req: Request(mist.Connection)) {
    let ip = client_ip(ctx, req)
    let req =
      req
      |> request.set_header("x-huddy-client-ip", ip)
    case request.path_segments(req) {
      ["events"] -> sse.handle(ctx, req)
      ["mcp"] -> transport.handle(ctx, req, transport.Bearer)
      ["mcp", "k", secret] ->
        transport.handle(ctx, req, transport.Secret(secret))
      ["mcp", ..] ->
        response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
      _ -> web(req)
    }
  }
}

/// The client's address: the peer, or (when the peer is a trusted proxy) the
/// right-most untrusted address in X-Forwarded-For.
fn client_ip(ctx: Ctx, req: Request(mist.Connection)) -> String {
  let peer = case mist.get_connection_info(req.body) {
    Ok(info) -> mist.ip_address_to_string(info.ip_address)
    Error(_) -> "unknown"
  }
  let trusted = fn(addr: String) {
    case net.parse_ip(addr) {
      Ok(ip) ->
        list.any(ctx.config.trusted_proxies, net.cidr_contains(
          _,
          net.normalize(ip),
        ))
      Error(_) -> False
    }
  }
  case trusted(peer), request.get_header(req, "x-forwarded-for") {
    True, Ok(chain) ->
      chain
      |> string.split(",")
      |> list.map(string.trim)
      |> list.reverse
      |> list.find(fn(addr) { !trusted(addr) })
      |> result.unwrap(peer)
    _, _ -> peer
  }
}

fn handle_web(ctx: Ctx, req: wisp.Request) -> wisp.Response {
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use <- wisp.serve_static(req, under: "/static", from: ctx.static_dir)
  case wisp.path_segments(req), req.method {
    [], http.Get -> board(ctx, req)
    ["healthz"], _ -> wisp.ok() |> wisp.string_body("ok")
    ["login", ..rest], _ -> login.handle(ctx, req, rest)
    ["logout"], http.Post -> login.logout(ctx, req)
    ["items", id, action], http.Post -> actions.handle(ctx, req, id, action)
    ["settings", ..rest], _ -> settings.handle(ctx, req, rest)
    [".well-known", "oauth-protected-resource"], http.Get
    | [".well-known", "oauth-protected-resource", "mcp"], http.Get
    -> oauth.protected_resource(ctx)
    [".well-known", "oauth-authorization-server"], http.Get
    | [".well-known", "oauth-authorization-server", "mcp"], http.Get
    -> oauth.authorization_server(ctx)
    ["oauth", "authorize"], _ -> oauth.authorize(ctx, req)
    ["oauth", "token"], http.Post -> oauth.token(ctx, req)
    ["oauth", "register"], http.Post -> oauth.register(ctx, req)
    ["oauth", "revoke"], http.Post -> oauth.revoke(ctx, req)
    _, _ -> wisp.not_found()
  }
}

fn board(ctx: Ctx, req: wisp.Request) -> wisp.Response {
  use user <- session.require_user(ctx, req)
  let filters = page.filters_from_query(wisp.get_query(req))
  let board = page.load(ctx, user, filters)
  layout.respond(200, page.render(ctx, board))
}
