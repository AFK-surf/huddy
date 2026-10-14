//// A tiny HTML builder. Text and attribute values are always escaped; `raw`
//// is only used for markup Huddy generates itself (e.g. sketch SVG).

import gleam/list
import gleam/string
import gleam/string_tree.{type StringTree}

pub type Node {
  Element(tag: String, attrs: List(#(String, String)), children: List(Node))
  Text(String)
  Raw(String)
  Fragment(List(Node))
}

pub fn el(
  tag: String,
  attrs: List(#(String, String)),
  children: List(Node),
) -> Node {
  Element(tag, attrs, children)
}

pub fn text(s: String) -> Node {
  Text(s)
}

pub fn raw(s: String) -> Node {
  Raw(s)
}

pub fn none() -> Node {
  Fragment([])
}

pub fn fragment(nodes: List(Node)) -> Node {
  Fragment(nodes)
}

pub fn when(condition: Bool, node: fn() -> Node) -> Node {
  case condition {
    True -> node()
    False -> Fragment([])
  }
}

// common elements
pub fn div(attrs, children) -> Node {
  el("div", attrs, children)
}

pub fn span(attrs, children) -> Node {
  el("span", attrs, children)
}

pub fn a(href: String, attrs: List(#(String, String)), children) -> Node {
  el("a", [#("href", href), ..attrs], children)
}

pub fn class(name: String) -> #(String, String) {
  #("class", name)
}

pub fn id(name: String) -> #(String, String) {
  #("id", name)
}

/// A POST form with hidden fields.
pub fn post_form(
  action: String,
  attrs: List(#(String, String)),
  hidden: List(#(String, String)),
  children: List(Node),
) -> Node {
  el(
    "form",
    [#("method", "post"), #("action", action), ..attrs],
    list.append(
      list.map(hidden, fn(h) {
        el("input", [#("type", "hidden"), #("name", h.0), #("value", h.1)], [])
      }),
      children,
    ),
  )
}

const void = [
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
  "source", "track", "wbr",
]

pub fn escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

pub fn to_tree(node: Node) -> StringTree {
  render(node, string_tree.new())
}

pub fn to_string(node: Node) -> String {
  to_tree(node) |> string_tree.to_string
}

fn render(node: Node, acc: StringTree) -> StringTree {
  case node {
    Text(s) -> string_tree.append(acc, escape(s))
    Raw(s) -> string_tree.append(acc, s)
    Fragment(children) -> list.fold(children, acc, fn(t, c) { render(c, t) })
    Element(tag, attrs, children) -> {
      let acc =
        list.fold(attrs, string_tree.append(acc, "<" <> tag), fn(t, at) {
          string_tree.append(t, " " <> at.0 <> "=\"" <> escape(at.1) <> "\"")
        })
        |> string_tree.append(">")
      case list.contains(void, tag) {
        True -> acc
        False ->
          list.fold(children, acc, fn(t, c) { render(c, t) })
          |> string_tree.append("</" <> tag <> ">")
      }
    }
  }
}

pub fn document(title: String, head: List(Node), body: List(Node)) -> String {
  "<!doctype html>"
  <> to_string(
    el("html", [#("lang", "en")], [
      el("head", [], [
        el("meta", [#("charset", "utf-8")], []),
        el(
          "meta",
          [
            #("name", "viewport"),
            #("content", "width=device-width, initial-scale=1"),
          ],
          [],
        ),
        el("title", [], [text(title)]),
        el("link", [#("rel", "stylesheet"), #("href", "/static/huddy.css")], []),
        el("link", [#("rel", "icon"), #("href", "/static/favicon.svg")], []),
        // installable as an app (see huddy/web/pwa)
        el(
          "link",
          [#("rel", "manifest"), #("href", "/manifest.webmanifest")],
          [],
        ),
        el(
          "link",
          [
            #("rel", "apple-touch-icon"),
            #("href", "/static/apple-touch-icon.png"),
          ],
          [],
        ),
        el(
          "meta",
          [
            #("name", "theme-color"),
            #("content", "#ffffff"),
            #("media", "(prefers-color-scheme: light)"),
          ],
          [],
        ),
        el(
          "meta",
          [
            #("name", "theme-color"),
            #("content", "#121212"),
            #("media", "(prefers-color-scheme: dark)"),
          ],
          [],
        ),
        el(
          "meta",
          [#("name", "mobile-web-app-capable"), #("content", "yes")],
          [],
        ),
        el(
          "meta",
          [#("name", "apple-mobile-web-app-title"), #("content", "Huddy")],
          [],
        ),
        el("script", [#("src", "/static/pwa.js"), #("defer", "")], []),
        fragment(head),
      ]),
      el("body", [], body),
    ]),
  )
}
