//// Email + verification-code login (§9.1).

import gleam/dict
import gleam/http
import gleam/http/request
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import huddy/config
import huddy/ctx.{type Ctx}
import huddy/ephemeral.{Ephemeral, LoginCode}
import huddy/state
import huddy/store
import huddy/sys
import huddy/web/html
import huddy/web/layout
import huddy/web/session
import wisp.{type Request, type Response}

pub fn handle(ctx: Ctx, req: Request, segments: List(String)) -> Response {
  case req.method, segments {
    http.Get, [] -> login_form(ctx, req, None)
    http.Post, [] -> request_code(ctx, req)
    http.Get, ["verify"] -> verify_form(ctx, req, None)
    http.Post, ["verify"] -> verify(ctx, req)
    _, _ -> wisp.not_found()
  }
}

pub fn logout(ctx: Ctx, req: Request) -> Response {
  case session.same_origin(ctx, req) {
    True ->
      wisp.redirect("/login")
      |> fn(resp) { session.end(ctx, req, resp) }
    False -> wisp.bad_request("cross-origin request")
  }
}

fn query(req: Request, name: String) -> String {
  wisp.get_query(req)
  |> list_key(name)
}

fn list_key(pairs: List(#(String, String)), name: String) -> String {
  case pairs {
    [] -> ""
    [#(k, v), ..] if k == name -> v
    [_, ..rest] -> list_key(rest, name)
  }
}

fn login_form(ctx: Ctx, req: Request, message: option.Option(html.Node)) -> Response {
  let return_to = session.safe_return_to(case query(req, "return_to") {
    "" -> "/"
    r -> r
  })
  layout.respond(
    200,
    layout.card_page(ctx, "Sign in", [
      html.el("h1", [], [html.text("Sign in")]),
      option.unwrap(message, html.none()),
      html.el("p", [], [
        html.text("We'll e-mail you a 6-digit code."),
      ]),
      html.post_form("/login", [], [#("return_to", return_to)], [
        layout.field(
          "Email",
          layout.input([
            #("type", "email"),
            #("name", "email"),
            #("required", ""),
            #("autofocus", ""),
            #("autocomplete", "email"),
          ]),
        ),
        layout.button("Send code", [#("type", "submit")]),
      ]),
    ]),
  )
}

fn request_code(ctx: Ctx, req: Request) -> Response {
  use form <- wisp.require_form(req)
  let email = session.form_value(form, "email") |> string.lowercase
  let return_to = session.safe_return_to(session.form_value(form, "return_to"))
  let ip = session.client_ip(req)
  case sys.rate_limit("login-ip:" <> ip, 10, 3_600_000) {
    False ->
      login_form(ctx, req, Some(layout.error("Too many attempts. Try again later.")))
    True -> {
      case config.email_allowed(ctx.config, email) {
        True -> send_code(ctx, email)
        False -> Nil
      }
      // Same response whether or not the email is allowed.
      wisp.redirect(
        "/login/verify?email="
        <> uri.percent_encode(email)
        <> "&return_to="
        <> uri.percent_encode(return_to),
      )
    }
  }
}

fn send_code(ctx: Ctx, email: String) -> Nil {
  let code = sys.random_code()
  let ttl = ctx.config.auth.code_ttl_minutes * 60_000
  let secret = ctx.config.secret_key
  let sent =
    store.update_lazy(ctx.store, fn(s, e, now) {
      case dict.get(e.login_codes, email) {
        Ok(existing) if now - existing.last_sent_at < 60_000 ->
          store.NoChange(False)
        _ -> {
          let entry =
            LoginCode(
              code_hmac: sys.hmac_hex(email <> ":" <> code, secret),
              expires_at: now + ttl,
              attempts: 0,
              last_sent_at: now,
            )
          let _ = s
          store.EphemeralChanged(
            Ephemeral(..e, login_codes: dict.insert(e.login_codes, email, entry)),
            True,
          )
        }
      }
    })
  case sent {
    True ->
      ctx.send_email(
        email,
        "Your Huddy sign-in code: " <> code,
        "Your code for "
          <> ctx.config.team_name
          <> " on Huddy is:\n\n    "
          <> code
          <> "\n\nIt expires in "
          <> int.to_string(ctx.config.auth.code_ttl_minutes)
          <> " minutes. If you didn't ask for it, ignore this e-mail.\n\n"
          <> ctx.config.base_url
          <> "\n",
      )
    False -> Nil
  }
}

fn verify_form(ctx: Ctx, req: Request, message: option.Option(html.Node)) -> Response {
  let email = query(req, "email")
  let return_to = session.safe_return_to(query(req, "return_to"))
  layout.respond(
    200,
    layout.card_page(ctx, "Check your e-mail", [
      html.el("h1", [], [html.text("Check your e-mail")]),
      option.unwrap(message, html.none()),
      html.el("p", [], [
        html.text("If " <> email <> " may sign in, we sent it a code."),
      ]),
      html.post_form(
        "/login/verify",
        [],
        [#("email", email), #("return_to", return_to)],
        [
          layout.field(
            "Code",
            layout.input([
              #("name", "code"),
              #("inputmode", "numeric"),
              #("pattern", "[0-9 ]*"),
              #("autocomplete", "one-time-code"),
              #("required", ""),
              #("autofocus", ""),
            ]),
          ),
          layout.button("Sign in", [#("type", "submit")]),
        ],
      ),
      html.el("p", [html.class("muted")], [
        html.a("/login", [], [html.text("Use a different e-mail")]),
      ]),
    ]),
  )
}

type Check {
  Valid
  Wrong
  Expired
}

fn verify(ctx: Ctx, req: Request) -> Response {
  use form <- wisp.require_form(req)
  let email = session.form_value(form, "email") |> string.lowercase
  let code = session.form_value(form, "code") |> string.replace(" ", "")
  let return_to = session.safe_return_to(session.form_value(form, "return_to"))
  let secret = ctx.config.secret_key
  let max = ctx.config.auth.code_max_attempts
  let hmac = sys.hmac_hex(email <> ":" <> code, secret)
  let check =
    store.update_lazy(ctx.store, fn(_s, e, now) {
      case dict.get(e.login_codes, email) {
        Error(_) -> store.NoChange(Expired)
        Ok(entry) ->
          case entry.expires_at < now || entry.attempts >= max {
            True ->
              store.EphemeralChanged(
                Ephemeral(..e, login_codes: dict.delete(e.login_codes, email)),
                Expired,
              )
            False ->
              case sys.secure_equal(entry.code_hmac, hmac) {
                True ->
                  store.EphemeralChanged(
                    Ephemeral(..e, login_codes: dict.delete(e.login_codes, email)),
                    Valid,
                  )
                False ->
                  store.EphemeralChanged(
                    Ephemeral(
                      ..e,
                      login_codes: dict.insert(
                        e.login_codes,
                        email,
                        LoginCode(..entry, attempts: entry.attempts + 1),
                      ),
                    ),
                    Wrong,
                  )
              }
          }
      }
    })
  let retry = fn(message) {
    let req = request.set_query(req, [#("email", email), #("return_to", return_to)])
    verify_form(ctx, req, Some(layout.error(message)))
  }
  case check, config.email_allowed(ctx.config, email) {
    Valid, True -> {
      let user =
        store.update(ctx.store, fn(s, e, now) {
          case state.user_by_email(s, email) {
            Some(u) -> store.NoChange(u)
            None -> {
              let #(s, u) = state.create_user(s, email, now)
              store.Changed(s, e, [], u)
            }
          }
        })
      case user {
        Ok(user) ->
          case session.start(ctx, req, wisp.redirect(return_to), user) {
            Ok(resp) -> resp
            Error(e) -> wisp.internal_server_error() |> wisp.string_body(e)
          }
        Error(e) -> wisp.internal_server_error() |> wisp.string_body(e)
      }
    }
    Wrong, _ -> retry("That code isn't right. Check it and try again.")
    _, _ -> retry("That code has expired or was used up. Request a new one.")
  }
}
