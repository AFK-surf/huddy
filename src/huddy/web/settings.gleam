//// Settings: connect agents (secret URLs, OAuth instructions), connected
//// OAuth clients, handle, and notification preferences.

import gleam/http
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import huddy/ctx.{type Ctx}
import huddy/fmt
import huddy/model.{type User}
import huddy/state
import huddy/store
import huddy/sys
import huddy/web/html.{type Node}
import huddy/web/layout
import huddy/web/session
import wisp.{type Request, type Response}

pub fn handle(ctx: Ctx, req: Request, segments: List(String)) -> Response {
  use user <- session.require_user(ctx, req)
  case req.method, segments {
    http.Get, [] -> page(ctx, user, None, None)
    http.Post, _ ->
      case session.same_origin(ctx, req) {
        False -> wisp.bad_request("cross-origin request")
        True -> {
          use form <- wisp.require_form(req)
          post(ctx, user, segments, form)
        }
      }
    _, _ -> wisp.not_found()
  }
}

fn post(
  ctx: Ctx,
  user: User,
  segments: List(String),
  form: wisp.FormData,
) -> Response {
  let value = session.form_value(form, _)
  case segments {
    ["links"] -> create_link(ctx, user, form)
    ["links", id, "revoke"] -> {
      let _ =
        store.update(ctx.store, fn(s, e, now) {
          case int.parse(id) {
            Ok(link_id) ->
              store.Changed(
                state.revoke_link(s, link_id, user.id, now),
                e,
                [],
                Nil,
              )
            Error(_) -> store.NoChange(Nil)
          }
        })
      wisp.redirect("/settings")
    }
    ["grants", id, "revoke"] -> {
      let _ =
        store.update(ctx.store, fn(s, e, now) {
          case int.parse(id) {
            Ok(grant_id) ->
              store.Changed(
                state.revoke_grant(s, grant_id, user.id, now),
                e,
                [],
                Nil,
              )
            Error(_) -> store.NoChange(Nil)
          }
        })
      wisp.redirect("/settings")
    }
    ["handle"] -> {
      let handle = value("handle") |> string.lowercase
      let result =
        store.update(ctx.store, fn(s, e, _) {
          case state.set_handle(s, user.id, handle) {
            Ok(s) -> store.Changed(s, e, [store.Publish], Ok(Nil))
            Error(reason) -> store.NoChange(Error(reason))
          }
        })
        |> result.flatten
      case result {
        Ok(_) -> wisp.redirect("/settings")
        Error(reason) -> page(ctx, user, None, Some(reason))
      }
    }
    ["notify"] -> {
      let browser = value("notify_browser_non_blocking") == "on"
      let _ =
        store.update(ctx.store, fn(s, e, _) {
          store.Changed(state.set_notify(s, user.id, browser), e, [], Nil)
        })
      wisp.redirect("/settings")
    }
    _ -> wisp.not_found()
  }
}

fn optional(text: String) -> Option(String) {
  case string.trim(text) {
    "" -> None
    t -> Some(state.slug(t))
  }
}

fn create_link(ctx: Ctx, user: User, form: wisp.FormData) -> Response {
  case ctx.config.mcp.secret_urls {
    False -> wisp.not_found()
    True -> {
      let label = case session.form_value(form, "label") {
        "" -> "agent"
        l -> fmt.clip(l, 60)
      }
      let scope = case session.form_value(form, "scope") {
        "read" -> "huddy:read"
        _ -> "huddy:read huddy:write"
      }
      let secret = sys.random_token(32)
      let created =
        store.update(ctx.store, fn(s, e, now) {
          let #(s, _) =
            state.create_link(
              s,
              user.id,
              sys.sha256_hex(secret),
              label,
              optional(session.form_value(form, "pinned_name")),
              optional(session.form_value(form, "pinned_project")),
              scope,
              now,
            )
          store.Changed(s, e, [], Nil)
        })
      case created {
        Ok(_) ->
          page(
            ctx,
            user,
            Some(ctx.config.base_url <> "/mcp/k/" <> secret),
            None,
          )
        Error(reason) -> page(ctx, user, None, Some(reason))
      }
    }
  }
}

fn page(
  ctx: Ctx,
  user: User,
  new_link: Option(String),
  error: Option(String),
) -> Response {
  let now = sys.now_ms()
  let #(links, grants, user) =
    store.read(ctx.store, fn(s, _) {
      let grants =
        state.grants_of(s, user.id)
        |> list.map(fn(g) {
          let name = case state.client(s, g.client_id) {
            Some(c) if c.client_name != "" -> c.client_name
            _ -> g.client_id
          }
          #(g, name)
        })
      #(
        state.links_of(s, user.id),
        grants,
        state.user(s, user.id) |> option.unwrap(user),
      )
    })
  let mcp_url = ctx.config.base_url <> "/mcp"
  layout.respond(
    200,
    layout.card_page(ctx, "Settings", [
      html.el("h1", [], [html.text("Settings")]),
      case error {
        Some(e) -> layout.error(e)
        None -> html.none()
      },
      html.el("h2", [], [html.text("Connect an agent")]),
      html.el("p", [], [
        html.text("Point your agent's MCP client at "),
        html.el("code", [], [html.text(mcp_url)]),
        html.text(". It signs in through your browser (OAuth). For example:"),
      ]),
      html.el("pre", [], [
        html.text(
          "claude mcp add --transport http huddy "
          <> mcp_url
          <> "\n\n# Codex (~/.codex/config.toml)\n[mcp_servers.huddy]\nurl = \""
          <> mcp_url
          <> "\"",
        ),
      ]),
      html.when(ctx.config.mcp.secret_urls, fn() {
        links_section(links, new_link, now)
      }),
      html.el("h2", [], [html.text("Connected clients (OAuth)")]),
      case grants {
        [] -> html.el("p", [html.class("muted")], [html.text("None yet.")])
        _ ->
          html.el(
            "ul",
            [html.class("rows")],
            list.map(grants, fn(pair) {
              let #(g, name) = pair
              html.el("li", [], [
                html.el("b", [], [html.text(name)]),
                html.text(
                  " · "
                  <> g.scope
                  <> " · approved "
                  <> fmt.ago(now, g.created_at)
                  <> case g.last_used_at {
                    Some(t) -> " · used " <> fmt.ago(now, t)
                    None -> ""
                  },
                ),
                revoke_form(
                  "/settings/grants/" <> int.to_string(g.id) <> "/revoke",
                ),
              ])
            }),
          )
      },
      html.el("h2", [], [html.text("You")]),
      html.post_form("/settings/handle", [html.class("row")], [], [
        layout.field(
          "Handle (the owner in owner/agent/project)",
          layout.input([
            #("name", "handle"),
            #("value", user.handle),
            #("required", ""),
          ]),
        ),
        layout.button("Save", [#("type", "submit")]),
      ]),
      html.post_form("/settings/notify", [], [], [
        checkbox(
          "notify_browser_non_blocking",
          user.notify_browser_non_blocking,
          "Browser notifications for non-blocking decisions too",
        ),
        layout.button("Save", [#("type", "submit")]),
      ]),
      html.el("p", [html.class("muted")], [
        html.text("Signed in as " <> user.email <> ". "),
        html.a("/", [], [html.text("Back to the board")]),
      ]),
    ]),
  )
}

fn checkbox(name: String, checked: Bool, label: String) -> Node {
  html.el("label", [html.class("check")], [
    html.el(
      "input",
      list.append([#("type", "checkbox"), #("name", name)], case checked {
        True -> [#("checked", "")]
        False -> []
      }),
      [],
    ),
    html.text(" " <> label),
  ])
}

fn revoke_form(action: String) -> Node {
  html.post_form(action, [html.class("inline")], [], [
    html.el("button", [html.class("linkish"), #("type", "submit")], [
      html.text("revoke"),
    ]),
  ])
}

fn links_section(
  links: List(model.McpLink),
  new_link: Option(String),
  now: Int,
) -> Node {
  html.fragment([
    html.el("h3", [], [html.text("Secret URLs")]),
    html.el("p", [], [
      html.text(
        "For clients without OAuth: a URL that is your credential. Treat it like a password.",
      ),
    ]),
    case new_link {
      Some(url) ->
        html.div([html.class("secret")], [
          html.el("p", [], [html.text("Your new URL (shown once):")]),
          html.el("pre", [], [html.text(url)]),
        ])
      None -> html.none()
    },
    case links {
      [] -> html.none()
      _ ->
        html.el(
          "ul",
          [html.class("rows")],
          list.map(links, fn(l) {
            html.el("li", [], [
              html.el("b", [], [html.text(l.label)]),
              html.text(
                " · "
                <> l.scope
                <> case l.pinned_name, l.pinned_project {
                  None, None -> ""
                  n, p ->
                    " · pinned to "
                    <> option.unwrap(n, "*")
                    <> "/"
                    <> option.unwrap(p, "*")
                }
                <> " · created "
                <> fmt.ago(now, l.created_at)
                <> case l.last_used_at {
                  Some(t) -> " · used " <> fmt.ago(now, t)
                  None -> " · never used"
                },
              ),
              revoke_form(
                "/settings/links/" <> int.to_string(l.id) <> "/revoke",
              ),
            ])
          }),
        )
    },
    html.post_form("/settings/links", [html.class("grid")], [], [
      layout.field(
        "Label",
        layout.input([
          #("name", "label"),
          #("placeholder", "laptop codex"),
          #("maxlength", "60"),
        ]),
      ),
      layout.field(
        "Agent name (optional)",
        layout.input([#("name", "pinned_name"), #("placeholder", "codex")]),
      ),
      layout.field(
        "Project (optional)",
        layout.input([#("name", "pinned_project"), #("placeholder", "my-repo")]),
      ),
      layout.field(
        "Scope",
        html.el("select", [#("name", "scope")], [
          html.el("option", [#("value", "write")], [html.text("read + write")]),
          html.el("option", [#("value", "read")], [html.text("read only")]),
        ]),
      ),
      layout.button("Create URL", [#("type", "submit")]),
    ]),
  ])
}
