//// Web sessions (cookie → hashed token in the state file), origin checks,
//// and small request helpers shared by the web handlers.

import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import huddy/config
import huddy/ctx.{type Ctx}
import huddy/model.{type User}
import huddy/state
import huddy/store
import huddy/sys
import wisp.{type Request, type Response}

pub const cookie_name = "huddy_session"

/// The signed-in user, if the session is valid and the email is still on the
/// allowlist (re-checked on every request).
pub fn current_user(ctx: Ctx, req: Request) -> Option(User) {
  case wisp.get_cookie(req, cookie_name, wisp.PlainText) {
    Ok(token) -> {
      let sha = sys.sha256_hex(token)
      let now = sys.now_ms()
      case store.read(ctx.store, fn(s, _) { state.session_user(s, sha, now) }) {
        Some(user) ->
          case config.email_allowed(ctx.config, user.email) {
            True -> Some(user)
            False -> None
          }
        None -> None
      }
    }
    Error(_) -> None
  }
}

pub fn require_user(
  ctx: Ctx,
  req: Request,
  next: fn(User) -> Response,
) -> Response {
  case current_user(ctx, req) {
    Some(user) -> next(user)
    None ->
      case req.method {
        _ -> {
          let target = case req.query {
            Some(q) -> req.path <> "?" <> q
            None -> req.path
          }
          wisp.redirect("/login?return_to=" <> uri.percent_encode(target))
        }
      }
  }
}

/// Create a session for `user` and set the cookie on `resp`.
pub fn start(ctx: Ctx, req: Request, resp: Response, user: User) -> Result(Response, String) {
  let token = sys.random_token(32)
  let sha = sys.sha256_hex(token)
  let ttl = ctx.config.auth.session_ttl_days * 86_400_000
  let user_agent = request.get_header(req, "user-agent") |> result.unwrap("")
  use _ <- result.try(
    store.update(ctx.store, fn(s, e, now) {
      let s =
        state.create_session(s, sha, user.id, now, ttl, user_agent)
        |> state.touch_login(user.id, now)
      store.Changed(s, e, [], Nil)
    }),
  )
  Ok(wisp.set_cookie(resp, req, cookie_name, token, wisp.PlainText, ttl / 1000))
}

pub fn end(ctx: Ctx, req: Request, resp: Response) -> Response {
  case wisp.get_cookie(req, cookie_name, wisp.PlainText) {
    Ok(token) -> {
      let sha = sys.sha256_hex(token)
      let _ =
        store.update(ctx.store, fn(s, e, _) {
          store.Changed(state.delete_session(s, sha), e, [], Nil)
        })
      Nil
    }
    Error(_) -> Nil
  }
  wisp.set_cookie(resp, req, cookie_name, "", wisp.PlainText, 0)
}

/// CSRF protection for cookie-authenticated POSTs: the Origin (or Referer)
/// must be Huddy's own origin.
pub fn same_origin(ctx: Ctx, req: Request) -> Bool {
  let expected = config.origin_of(ctx.config.base_url)
  let from_header = case request.get_header(req, "origin") {
    Ok(o) -> config.origin_of(o)
    Error(_) ->
      case request.get_header(req, "referer") {
        Ok(r) -> config.origin_of(r)
        Error(_) -> None
      }
  }
  case expected, from_header {
    Some(a), Some(b) -> a == b
    _, _ -> False
  }
}

pub fn client_ip(req: Request) -> String {
  request.get_header(req, "x-huddy-client-ip") |> result.unwrap("unknown")
}

/// Only local paths are acceptable redirect targets.
pub fn safe_return_to(target: String) -> String {
  case
    string.starts_with(target, "/")
    && !string.starts_with(target, "//")
    && !string.contains(target, "\\")
  {
    True -> target
    False -> "/"
  }
}

/// Requests sent by the page's fetch() upgrade get 204 instead of a redirect.
pub fn done(req: Request, return_to: String) -> Response {
  case request.get_header(req, "x-huddy-fetch") {
    Ok(_) -> wisp.no_content()
    Error(_) -> wisp.redirect(safe_return_to(return_to))
  }
}

pub fn form_value(form: wisp.FormData, name: String) -> String {
  list.key_find(form.values, name) |> result.unwrap("") |> string.trim
}

pub fn no_store(resp: Response) -> Response {
  response.set_header(resp, "cache-control", "no-store")
}
