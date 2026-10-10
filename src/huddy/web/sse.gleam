//// Live updates (§9.3): one process per open page. It subscribes to the
//// store, re-renders the page's zones on change (coalesced over 250 ms),
//// sends only zones whose HTML changed, forwards decision notifications,
//// and pings every 25 s.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string_tree
import huddy/config
import huddy/ctx.{type Ctx}
import huddy/model.{type User}
import huddy/rank
import huddy/state
import huddy/store.{type BoardEvent}
import huddy/sys
import huddy/web/page
import huddy/web/session
import mist

type Conn {
  Conn(
    ctx: Ctx,
    subject: Subject(BoardEvent),
    token_sha: String,
    user: User,
    filters: rank.Filters,
    sent: Dict(String, String),
    pending: Bool,
  )
}

/// The user behind the session cookie (mist-level request, no wisp).
fn session_user(
  ctx: Ctx,
  req: Request(mist.Connection),
) -> Option(#(String, User)) {
  let token =
    request.get_cookies(req)
    |> list.key_find(session.cookie_name)
    |> result.try(bit_array.base64_decode)
    |> result.try(bit_array.to_string)
  case token {
    Ok(token) -> {
      let sha = sys.sha256_hex(token)
      validate(ctx, sha) |> option.map(fn(u) { #(sha, u) })
    }
    Error(_) -> None
  }
}

fn validate(ctx: Ctx, sha: String) -> Option(User) {
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

pub fn handle(
  ctx: Ctx,
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case session_user(ctx, req) {
    None ->
      response.new(401)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("sign in first")))
    Some(#(sha, user)) -> {
      let query = request.get_query(req) |> result.unwrap([])
      let filters = page.filters_from_query(query)
      let stale_page = case list.key_find(query, "boot") {
        Ok(b) -> b != ctx.boot_id
        Error(_) -> False
      }
      mist.server_sent_events(
        req,
        response.new(200) |> response.set_header("x-accel-buffering", "no"),
        init: fn(subject) {
          store.subscribe(ctx.store, subject, user.id)
          process.send_after(subject, 25_000, store.SseTick)
          process.send(subject, store.SseRender)
          Conn(
            ctx:,
            subject:,
            token_sha: sha,
            user:,
            filters:,
            sent: dict.new(),
            pending: True,
          )
          |> fn(conn) {
            case stale_page {
              True -> Conn(..conn, sent: dict.insert(conn.sent, "__reload", ""))
              False -> conn
            }
          }
        },
        loop: loop,
      )
    }
  }
}

fn send(
  conn: mist.SSEConnection,
  name: String,
  data: String,
) -> Result(Nil, Nil) {
  mist.send_event(
    conn,
    mist.event(string_tree.from_string(data)) |> mist.event_name(name),
  )
}

fn stop(c: Conn) -> actor.Next(Conn, BoardEvent) {
  store.unsubscribe(c.ctx.store, c.subject)
  actor.stop()
}

fn loop(
  c: Conn,
  msg: BoardEvent,
  conn: mist.SSEConnection,
) -> actor.Next(Conn, BoardEvent) {
  case msg {
    store.BoardChanged ->
      case c.pending {
        True -> actor.continue(c)
        False -> {
          process.send_after(c.subject, 250, store.SseRender)
          actor.continue(Conn(..c, pending: True))
        }
      }
    store.SseRender -> {
      let c = Conn(..c, pending: False)
      case dict.has_key(c.sent, "__reload") {
        True -> {
          let _ = send(conn, "reload", "")
          stop(c)
        }
        False ->
          case validate(c.ctx, c.token_sha) {
            None -> {
              let _ = send(conn, "reload", "")
              stop(c)
            }
            Some(user) -> {
              let board = page.load(c.ctx, user, c.filters)
              let zones = page.zones(c.ctx, board)
              let result =
                list.try_fold(zones, c.sent, fn(sent, zone) {
                  let #(id, html) = zone
                  case dict.get(sent, id) {
                    Ok(previous) if previous == html -> Ok(sent)
                    _ ->
                      send(conn, "swap", html)
                      |> result.map(fn(_) { dict.insert(sent, id, html) })
                  }
                })
              case result {
                Ok(sent) -> actor.continue(Conn(..c, user:, sent:))
                Error(_) -> stop(c)
              }
            }
          }
      }
    }
    store.Notify(payload) ->
      case send(conn, "notify", payload) {
        Ok(_) -> actor.continue(c)
        Error(_) -> stop(c)
      }
    store.SseTick -> {
      process.send_after(c.subject, 25_000, store.SseTick)
      case send(conn, "ping", "") {
        Ok(_) -> actor.continue(c)
        Error(_) -> stop(c)
      }
    }
  }
}
