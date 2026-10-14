//// What makes Huddy installable as an app: the web app manifest, the service
//// worker (served from the root so it controls every page) and the page it
//// shows when the server can't be reached.

import gleam/json
import gleam/option.{None}
import huddy/ctx.{type Ctx}
import huddy/web/html
import huddy/web/layout
import wisp.{type Response}

/// The board's paper colour, for the title bar and the splash screen.
pub const theme_color = "#ffffff"

/// Browsers fetch the manifest without cookies, so it is public; it names
/// only the team, which the login page shows too.
pub fn manifest(ctx: Ctx) -> Response {
  let icon = fn(src, size, type_, purpose) {
    json.object([
      #("src", json.string(src)),
      #("sizes", json.string(size)),
      #("type", json.string(type_)),
      #("purpose", json.string(purpose)),
    ])
  }
  json.object([
    #("id", json.string("/")),
    #("name", json.string("Huddy · " <> ctx.config.team_name)),
    #("short_name", json.string("Huddy")),
    #(
      "description",
      json.string("A heads-up display for a team's coding agents"),
    ),
    #("start_url", json.string("/")),
    #("scope", json.string("/")),
    #("display", json.string("standalone")),
    #("background_color", json.string(theme_color)),
    #("theme_color", json.string(theme_color)),
    #(
      "icons",
      json.preprocessed_array([
        icon("/static/icon-192.png", "192x192", "image/png", "any"),
        icon("/static/icon-512.png", "512x512", "image/png", "any"),
        icon("/static/favicon.svg", "any", "image/svg+xml", "any"),
        icon(
          "/static/icon-maskable-512.png",
          "512x512",
          "image/png",
          "maskable",
        ),
      ]),
    ),
  ])
  |> json.to_string
  |> wisp.json_response(200)
  |> wisp.set_header("content-type", "application/manifest+json")
  |> wisp.set_header("cache-control", "no-cache")
}

/// The service worker lives in `priv/static/sw.js` but is served from `/` so
/// that its scope covers the whole site; `no-cache` lets a deploy replace it.
pub fn service_worker(ctx: Ctx) -> Response {
  wisp.ok()
  |> wisp.set_body(wisp.File(
    path: ctx.static_dir <> "/sw.js",
    offset: 0,
    limit: None,
  ))
  |> wisp.set_header("content-type", "text/javascript; charset=utf-8")
  |> wisp.set_header("cache-control", "no-cache")
}

/// Cached by the service worker and shown in place of any page that fails to
/// load; following the link retries the page that failed.
pub fn offline(ctx: Ctx) -> Response {
  layout.respond(
    200,
    layout.card_page(ctx, "Offline", [
      html.el("h1", [], [html.text("You're offline")]),
      html.el("p", [], [
        html.text("Huddy can't reach its server right now."),
      ]),
      html.el("p", [], [html.a("", [], [html.text("Try again")])]),
    ]),
  )
}
