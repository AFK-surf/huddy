//// Page shells shared by the board, login, settings and consent pages.

import gleam/option.{None}
import huddy/ctx.{type Ctx}
import huddy/web/html.{type Node}
import huddy/web/sketch
import wisp.{type Response}

pub fn respond(status: Int, document: String) -> Response {
  wisp.html_response(document, status)
  |> wisp.set_header("cache-control", "no-store")
  |> wisp.set_header("x-frame-options", "DENY")
  |> wisp.set_header("referrer-policy", "same-origin")
}

/// A small centred card, used for login, settings and consent.
pub fn card_page(ctx: Ctx, title: String, body: List(Node)) -> String {
  html.document(title <> " · Huddy", [], [
    html.div([html.class("narrow")], [
      html.el("header", [html.class("mini")], [
        html.a("/", [html.class("logo")], [html.text("Huddy")]),
        html.span([html.class("team")], [html.text(ctx.config.team_name)]),
      ]),
      html.div([html.class("card sk")], [
        html.raw(sketch.frame(
          "card:" <> title,
          sketch.Rect,
          560,
          360,
          "ink",
          None,
        )),
        html.fragment(body),
      ]),
    ]),
  ])
}

pub fn notice(text: String) -> Node {
  html.el("p", [html.class("notice")], [html.text(text)])
}

pub fn error(text: String) -> Node {
  html.el("p", [html.class("error")], [html.text(text)])
}

pub fn field(label: String, input: Node) -> Node {
  html.el("label", [html.class("field")], [
    html.span([], [html.text(label)]),
    input,
  ])
}

pub fn input(attrs: List(#(String, String))) -> Node {
  html.el("input", attrs, [])
}

pub fn button(label: String, attrs: List(#(String, String))) -> Node {
  html.el("button", [html.class("btn sk"), ..attrs], [
    html.raw(sketch.frame("btn:" <> label, sketch.Rect, 120, 30, "ink", None)),
    html.text(label),
  ])
}
