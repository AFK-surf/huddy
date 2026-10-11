//// Documents on the web: the list, one document (its Markdown is rendered in
//// the browser by `priv/static/huddy-doc.js`), its raw files, a zip
//// download, deletion by a human, and the one-time upload URL agents get
//// from `huddy_doc_upload`.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import huddy/blob
import huddy/config
import huddy/ctx.{type Ctx}
import huddy/documents
import huddy/ephemeral.{Ephemeral}
import huddy/fmt
import huddy/mcp/tools
import huddy/model.{type Document, type Item, type User}
import huddy/state
import huddy/store
import huddy/sys
import huddy/web/html.{type Node}
import huddy/web/layout
import huddy/web/session
import huddy/web/sketch
import mist
import wisp

pub fn handle(
  ctx: Ctx,
  req: wisp.Request,
  rest: List(String),
) -> wisp.Response {
  use user <- session.require_user(ctx, req)
  let rest = list.map(rest, fn(s) { uri.percent_decode(s) |> result.unwrap(s) })
  case rest, req.method {
    [], http.Get -> list_page(ctx, req, user)
    [ref], http.Get -> with_doc(ctx, ref, show(ctx, req, user, _))
    [ref, "files", ..path], http.Get ->
      with_doc(ctx, ref, file(ctx, _, string.join(path, "/")))
    [ref, "download"], http.Get -> with_doc(ctx, ref, download(ctx, _))
    [ref, "delete"], http.Post -> delete(ctx, req, user, ref)
    _, _ -> wisp.not_found()
  }
}

fn find(ctx: Ctx, ref: String) -> Option(Document) {
  case model.parse_ref(ref, "doc") {
    Ok(id) -> store.read(ctx.store, fn(s, _) { state.get_document(s, id) })
    Error(_) -> None
  }
}

fn with_doc(
  ctx: Ctx,
  ref: String,
  next: fn(Document) -> wisp.Response,
) -> wisp.Response {
  case find(ctx, ref) {
    Some(doc) -> next(doc)
    None -> layout.respond(404, not_found(ctx))
  }
}

// --- pages ---------------------------------------------------------------------

/// A script, with the Subresource Integrity hash of a third-party one.
type Script {
  Script(src: String, integrity: Option(String))
}

// The Markdown renderer and sanitizer, from jsDelivr, pinned by version and
// by hash: the browser refuses them if the CDN serves other bytes.
const marked =
  Script(
    "https://cdn.jsdelivr.net/npm/marked@18.0.14/lib/marked.umd.js",
    Some(
      "sha384-2vpGtuKqJvFlwJqYnf/wUMuzUfhUnYBt9oay0e2yaFcq0Dh6/aEbQ8YAOeKGzlYo",
    ),
  )

const dompurify =
  Script(
    "https://cdn.jsdelivr.net/npm/dompurify@3.4.15/dist/purify.min.js",
    Some(
      "sha384-uUMu9JDY09vBzRf9SPcK2VgUj+W/70J6Soc+Dded5P474ElQ63iv9j5N3DE7Kp3N",
    ),
  )

fn shell(ctx: Ctx, title: String, scripts: List(Script), body: List(Node)) {
  html.document(
    title <> " · Huddy",
    list.map(scripts, fn(script) {
      html.el(
        "script",
        [
          #("src", script.src),
          #("defer", ""),
          ..case script.integrity {
            Some(hash) -> [
              #("integrity", hash),
              #("crossorigin", "anonymous"),
              #("referrerpolicy", "no-referrer"),
            ]
            None -> []
          }
        ],
        [],
      )
    }),
    [
      html.div([html.class("page")], [
        html.el("header", [html.class("mini")], [
          html.a("/", [html.class("logo")], [html.text("Huddy")]),
          html.span([html.class("team")], [html.text(ctx.config.team_name)]),
          html.el("nav", [html.class("links")], [
            html.a("/", [], [html.text("board")]),
            html.a("/docs", [], [html.text("documents")]),
          ]),
        ]),
        html.fragment(body),
      ]),
    ],
  )
}

fn not_found(ctx: Ctx) -> String {
  shell(ctx, "No such document", [], [
    html.el("h1", [], [html.text("No such document")]),
    html.el("p", [], [
      html.text("It may have been deleted. "),
      html.a("/docs", [], [html.text("All documents")]),
    ]),
  ])
}

fn list_page(ctx: Ctx, req: wisp.Request, _user: User) -> wisp.Response {
  let now = sys.now_ms()
  let query =
    list.key_find(wisp.get_query(req), "q")
    |> result.unwrap("")
    |> string.trim
  let docs =
    store.read(ctx.store, fn(s, _) {
      state.documents(s)
      |> list.filter(fn(d) {
        query == ""
        || string.contains(string.lowercase(d.title), string.lowercase(query))
      })
      |> list.map(fn(d) {
        #(d, state.doc_byline(s, d), list.length(state.items_with_doc(s, d.id)))
      })
    })
  let deleted = list.key_find(wisp.get_query(req), "deleted") |> result.is_ok
  layout.respond(
    200,
    shell(ctx, "Documents", [], [
      html.el("h1", [], [html.text("Documents")]),
      html.el("p", [html.class("muted")], [
        html.text(
          "Markdown documents uploaded by agents. They are shared: every agent and everyone on the team can read them, and agents can replace or delete any of them.",
        ),
      ]),
      html.when(deleted, fn() { layout.notice("Document deleted.") }),
      html.el(
        "form",
        [#("method", "get"), #("action", "/docs"), html.class("search")],
        [
          html.el(
            "input",
            [
              #("type", "search"),
              #("name", "q"),
              #("value", query),
              #("placeholder", "filter by title"),
              #("aria-label", "Filter documents by title"),
            ],
            [],
          ),
        ],
      ),
      case docs {
        [] ->
          html.el("p", [html.class("muted")], [
            html.text(case query {
              "" -> "No documents yet."
              _ -> "No document matches."
            }),
          ])
        _ ->
          html.el(
            "ul",
            [html.class("doclist")],
            list.map(docs, fn(entry) {
              let #(d, label, links) = entry
              let ref = model.doc_ref(d.id)
              html.el("li", [html.class("docrow")], [
                html.raw(sketch.icon(sketch.DocIcon, ref)),
                html.div([], [
                  html.a("/docs/" <> ref, [html.class("t")], [
                    html.text(d.title),
                  ]),
                  html.div([html.class("meta")], [
                    html.text(
                      ref
                      <> " · "
                      <> label
                      <> " · revision "
                      <> int.to_string(d.version)
                      <> " · updated "
                      <> fmt.ago(now, d.updated_at)
                      <> " · "
                      <> documents.files_label(d.files)
                      <> ", "
                      <> documents.size_label(d.size)
                      <> case links {
                        0 -> ""
                        1 -> " · linked from 1 item"
                        n -> " · linked from " <> int.to_string(n) <> " items"
                      },
                    ),
                  ]),
                ]),
              ])
            }),
          )
      },
    ]),
  )
}

fn show(
  ctx: Ctx,
  req: wisp.Request,
  _user: User,
  doc: Document,
) -> wisp.Response {
  let now = sys.now_ms()
  let ref = model.doc_ref(doc.id)
  let path =
    list.key_find(wisp.get_query(req), "path")
    |> result.try(documents.normalize_path)
    |> result.unwrap("index.md")
  let is_markdown =
    string.ends_with(path, ".md") || string.ends_with(path, ".markdown")
  let #(label, items) =
    store.read(ctx.store, fn(s, _) {
      #(
        state.doc_byline(s, doc),
        state.items_with_doc(s, doc.id)
          |> list.map(fn(i) { #(i, state.agent_label(s, i.agent)) }),
      )
    })
  let source = case is_markdown {
    True -> documents.read_file(ctx, doc, path)
    False -> Error("enoent")
  }
  case source {
    Error("enoent") -> layout.respond(404, not_found(ctx))
    Error(reason) -> {
      wisp.log_error(
        "documents: cannot read " <> ref <> "/" <> path <> ": " <> reason,
      )
      layout.respond(
        500,
        shell(ctx, doc.title, [], [
          html.el("h1", [], [html.text(doc.title)]),
          layout.error(
            "The document's files cannot be read right now: " <> reason,
          ),
        ]),
      )
    }
    Ok(bits) -> {
      let source =
        bit_array.to_string(bits) |> result.unwrap("(not valid UTF-8 text)")
      layout.respond(
        200,
        shell(
          ctx,
          doc.title,
          [marked, dompurify, Script("/static/huddy-doc.js", None)],
          [
            html.el("article", [html.class("doc")], [
              html.div([html.class("dochead")], [
                html.el("h1", [], [html.text(doc.title)]),
                html.div([html.class("meta")], [
                  html.text(
                    ref
                    <> " · uploaded by "
                    <> label
                    <> " · revision "
                    <> int.to_string(doc.version)
                    <> " · updated "
                    <> fmt.ago(now, doc.updated_at)
                    <> " · "
                    <> documents.files_label(doc.files)
                    <> ", "
                    <> documents.size_label(doc.size),
                  ),
                ]),
                html.when(path != "index.md", fn() {
                  html.div([html.class("crumbs")], [
                    html.a("/docs/" <> ref, [], [html.text("index.md")]),
                    html.text(" / " <> path),
                  ])
                }),
              ]),
              // The raw Markdown, shown as-is without JavaScript; the script
              // renders it into #doc-body.
              html.el(
                "pre",
                [
                  html.id("doc-src"),
                  html.class("doc-src"),
                  #("data-base", "/docs/" <> ref),
                  #("data-path", path),
                  #("data-title", doc.title),
                  #(
                    "data-files",
                    string.join(list.map(doc.files, fn(f) { f.path }), "\n"),
                  ),
                ],
                [html.text(source)],
              ),
              html.div(
                [html.id("doc-body"), html.class("doc-body"), #("hidden", "")],
                [],
              ),
            ]),
            html.el("aside", [html.class("docside")], [
              html.el("h2", [], [html.text("Linked from")]),
              case items {
                [] ->
                  html.el("p", [html.class("muted")], [
                    html.text("No items link to this document."),
                  ])
                _ ->
                  html.el(
                    "ul",
                    [html.class("rows")],
                    list.map(items, linked_item),
                  )
              },
              html.el("h2", [], [html.text("Files")]),
              html.el(
                "ul",
                [html.class("rows")],
                list.map(doc.files, fn(f) {
                  html.el("li", [], [
                    html.a(file_href(ref, f.path), [], [html.text(f.path)]),
                    html.span([html.class("muted")], [
                      html.text(" · " <> documents.size_label(f.size)),
                    ]),
                  ])
                }),
              ),
              html.div([html.class("opts")], [
                html.a("/docs/" <> ref <> "/download", [html.class("btn sk")], [
                  html.raw(sketch.frame(
                    ref <> ":zip",
                    sketch.Rect,
                    120,
                    30,
                    "ink",
                    None,
                  )),
                  html.text("download .zip"),
                ]),
                html.el("details", [html.class("hide")], [
                  html.el("summary", [], [html.text("delete")]),
                  html.post_form(
                    "/docs/" <> ref <> "/delete",
                    [],
                    // the revision shown: a newer one is not deleted unseen
                    [#("revision", int.to_string(doc.version))],
                    [
                      html.el("span", [html.class("muted")], [
                        html.text(
                          "Deletes every version for everyone and unlinks it from items. ",
                        ),
                      ]),
                      html.el(
                        "button",
                        [html.class("linkish"), #("type", "submit")],
                        [
                          html.text("delete " <> ref),
                        ],
                      ),
                    ],
                  ),
                ]),
              ]),
            ]),
          ],
        ),
      )
    }
  }
}

fn linked_item(pair: #(Item, String)) -> Node {
  let #(i, label) = pair
  let ref = model.item_ref(i.id)
  html.el("li", [], [
    case model.is_open(i) {
      True -> html.a("/#" <> ref, [], [html.text(i.title)])
      False -> html.span([], [html.text(i.title)])
    },
    html.span([html.class("muted")], [
      html.text(
        " · "
        <> model.kind_to_string(i.kind)
        <> " "
        <> ref
        <> " · "
        <> label
        <> case model.is_open(i) {
          True -> ""
          False -> " · " <> model.state_to_string(i.state)
        },
      ),
    ]),
  ])
}

fn file_href(ref: String, path: String) -> String {
  "/docs/"
  <> ref
  <> "/files/"
  <> string.split(path, "/") |> list.map(uri.percent_encode) |> string.join("/")
}

/// A file of the document, served so that nothing in it can run on Huddy's
/// origin: a sandboxing CSP (which also covers SVG opened directly), no
/// sniffing, and anything that is not an image or text is a download.
fn file(ctx: Ctx, doc: Document, path: String) -> wisp.Response {
  case documents.normalize_path(path) {
    Error(_) -> wisp.not_found()
    Ok(path) ->
      case documents.read_file(ctx, doc, path) {
        Error("enoent") -> wisp.not_found()
        Error(reason) -> {
          wisp.log_error("documents: cannot read " <> path <> ": " <> reason)
          wisp.internal_server_error()
        }
        Ok(bits) -> {
          let content_type = case blob.content_type(path) {
            "text/" <> _ -> "text/plain; charset=utf-8"
            t -> t
          }
          let inline =
            string.starts_with(content_type, "image/")
            || string.starts_with(content_type, "text/")
            || content_type == "application/json"
          let resp =
            wisp.response(200)
            |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(bits)))
            |> wisp.set_header("content-type", content_type)
            |> wisp.set_header("x-content-type-options", "nosniff")
            |> wisp.set_header(
              "content-security-policy",
              "sandbox; default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'",
            )
            |> wisp.set_header("cache-control", "private, max-age=300")
            |> wisp.set_header("referrer-policy", "same-origin")
          case inline {
            True -> resp
            False ->
              wisp.set_header(
                resp,
                "content-disposition",
                "attachment; filename=\"" <> safe_filename(path) <> "\"",
              )
          }
        }
      }
  }
}

fn safe_filename(path: String) -> String {
  list.last(string.split(path, "/"))
  |> result.unwrap("file")
  |> string.to_graphemes
  |> list.map(fn(c) {
    case c == "\"" || c == "\\" || string.byte_size(c) > 1 {
      True -> "_"
      False -> c
    }
  })
  |> string.concat
}

fn download(ctx: Ctx, doc: Document) -> wisp.Response {
  case documents.zip(ctx, doc) {
    Error(reason) -> {
      wisp.log_error(
        "documents: cannot zip " <> model.doc_ref(doc.id) <> ": " <> reason,
      )
      wisp.internal_server_error()
    }
    Ok(bits) ->
      wisp.response(200)
      |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(bits)))
      |> wisp.set_header("content-type", "application/zip")
      |> wisp.set_header(
        "content-disposition",
        "attachment; filename=\"" <> model.doc_ref(doc.id) <> ".zip\"",
      )
      |> wisp.set_header("cache-control", "private, no-store")
  }
}

fn delete(
  ctx: Ctx,
  req: wisp.Request,
  user: User,
  ref: String,
) -> wisp.Response {
  case session.same_origin(ctx, req), model.parse_ref(ref, "doc") {
    False, _ -> wisp.bad_request("cross-origin request")
    _, Error(_) -> wisp.not_found()
    True, Ok(id) -> {
      use form <- wisp.require_form(req)
      case int.parse(session.form_value(form, "revision")) {
        Error(_) -> wisp.bad_request("missing revision")
        Ok(revision) ->
          case
            documents.delete(
              ctx,
              model.DocRevision(id:, revision:),
              state.user_actor(user.id),
            )
          {
            Ok(_) -> wisp.redirect("/docs?deleted=1")
            Error(reason) -> wisp.bad_request(reason)
          }
      }
    }
  }
}

// --- download URL ------------------------------------------------------------------

/// `GET /docs/download/<secret>`: the zip of the revision the link was
/// issued for. The link works once and only for 15 minutes; if the document
/// has changed or been deleted since, it is gone (410).
pub fn download_link(
  ctx: Ctx,
  req: Request(mist.Connection),
  secret: String,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> serve_download(ctx, secret)
    _ ->
      response.new(405)
      |> response.set_header("allow", "GET")
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn serve_download(ctx: Ctx, secret: String) -> Response(mist.ResponseData) {
  let sha = sys.sha256_hex(secret)
  let now = sys.now_ms()
  // take the link, so it works once
  let link =
    store.update_lazy(ctx.store, fn(s, e, _) {
      case dict.get(e.doc_downloads, sha) {
        Ok(d) ->
          store.EphemeralChanged(
            Ephemeral(..e, doc_downloads: dict.delete(e.doc_downloads, sha)),
            Some(#(d, state.user(s, d.user), state.get_document(s, d.doc.id))),
          )
        Error(_) -> store.NoChange(None)
      }
    })
  case link {
    Some(#(d, Some(user), doc)) if d.expires_at > now ->
      case config.email_allowed(ctx.config, user.email), doc {
        False, _ ->
          reply(404, [#("error", json.string("unknown or expired link"))])
        True, Some(doc) if doc.version == d.doc.revision ->
          case documents.zip(ctx, doc) {
            Ok(bits) ->
              response.new(200)
              |> response.set_header("content-type", "application/zip")
              |> response.set_header(
                "content-disposition",
                "attachment; filename=\""
                  <> model.doc_ref(doc.id)
                  <> "-r"
                  <> int.to_string(doc.version)
                  <> ".zip\"",
              )
              |> response.set_header("cache-control", "no-store")
              |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bits)))
            Error(reason) -> {
              // give the link back so the agent can retry
              store.update_lazy(ctx.store, fn(_, e, _) {
                store.EphemeralChanged(
                  Ephemeral(
                    ..e,
                    doc_downloads: dict.insert(e.doc_downloads, sha, d),
                  ),
                  Nil,
                )
              })
              reply(503, [
                #("error", json.string("Cannot read the document: " <> reason)),
              ])
            }
          }
        True, _ ->
          reply(410, [
            #(
              "error",
              json.string(
                model.doc_ref(d.doc.id)
                <> " has changed or been deleted since this link was issued; ask huddy_doc_download for a new one.",
              ),
            ),
          ])
      }
    _ -> reply(404, [#("error", json.string("unknown or expired link"))])
  }
}

// --- upload URL ------------------------------------------------------------------

/// `POST /docs/upload/<secret>`: the body is a zip archive or Markdown. The
/// URL works once and only for 15 minutes; a rejected upload can be retried.
pub fn upload(
  ctx: Ctx,
  req: Request(mist.Connection),
  secret: String,
) -> Response(mist.ResponseData) {
  let sha = sys.sha256_hex(secret)
  let pending =
    store.read(ctx.store, fn(s, e) {
      case dict.get(e.doc_uploads, sha) {
        Ok(u) ->
          case
            state.get_agent(s, u.agent)
            |> option.then(fn(a) { state.user(s, a.owner) })
          {
            Some(owner) -> Some(#(u, owner))
            None -> None
          }
        Error(_) -> None
      }
    })
  let now = sys.now_ms()
  case req.method, pending {
    http.Post, Some(#(u, owner))
    | http.Put, Some(#(u, owner))
      if u.expires_at > now
    ->
      case config.email_allowed(ctx.config, owner.email) {
        False ->
          reply(404, [#("error", json.string("unknown or expired upload URL"))])
        True -> {
          let limit =
            documents.max_bytes(ctx) + documents.max_bytes(ctx) / 10 + 65_536
          case mist.read_body(req, limit) {
            Error(_) ->
              reply(413, [
                #(
                  "error",
                  json.string(
                    "The upload is larger than "
                    <> int.to_string(ctx.config.limits.document_max_mb)
                    <> " MB.",
                  ),
                ),
              ])
            Ok(req) -> {
              // take the URL, so a concurrent upload with it fails
              let taken =
                store.update_lazy(ctx.store, fn(_, e, _) {
                  case dict.get(e.doc_uploads, sha) {
                    Ok(_) ->
                      store.EphemeralChanged(
                        Ephemeral(
                          ..e,
                          doc_uploads: dict.delete(e.doc_uploads, sha),
                        ),
                        True,
                      )
                    Error(_) -> store.NoChange(False)
                  }
                })
              case taken {
                False ->
                  reply(404, [
                    #("error", json.string("unknown or expired upload URL")),
                  ])
                True -> {
                  let result =
                    documents.detect(req.body)
                    |> result.map_error(documents.NotStored)
                    |> result.try(documents.upload(
                      ctx,
                      u.agent,
                      _,
                      u.title,
                      u.replaces,
                    ))
                  case result {
                    Ok(documents.Stored(doc, durable: True)) -> {
                      let r = tools.uploaded(ctx, doc)
                      reply(200, [
                        #("message", json.string(r.text)),
                        #("document", r.structured),
                      ])
                    }
                    // In memory, saved when the state write is retried: the
                    // URL stays used up, or a retry would store it twice.
                    Ok(documents.Stored(doc, durable: False)) -> {
                      let r = tools.uploaded(ctx, doc)
                      reply(202, [
                        #(
                          "message",
                          json.string(
                            r.text
                            <> " Huddy could not save its state just now; the document is kept in memory and saved when storage recovers. Do not upload it again.",
                          ),
                        ),
                        #("document", r.structured),
                      ])
                    }
                    Error(documents.NotStored(reason)) -> {
                      // give the URL back so the agent can fix and retry
                      store.update_lazy(ctx.store, fn(_, e, _) {
                        store.EphemeralChanged(
                          Ephemeral(
                            ..e,
                            doc_uploads: dict.insert(e.doc_uploads, sha, u),
                          ),
                          Nil,
                        )
                      })
                      reply(400, [
                        #("error", json.string("Not stored: " <> reason)),
                      ])
                    }
                    Error(documents.Unknown(reason)) ->
                      reply(503, [
                        #(
                          "error",
                          json.string(
                            reason
                            <> " Check huddy_doc_list before uploading again; this URL is used up.",
                          ),
                        ),
                      ])
                  }
                }
              }
            }
          }
        }
      }
    http.Post, _ | http.Put, _ ->
      reply(404, [#("error", json.string("unknown or expired upload URL"))])
    _, _ ->
      response.new(405)
      |> response.set_header("allow", "POST, PUT")
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn reply(
  status: Int,
  fields: List(#(String, json.Json)),
) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      json.to_string(json.object(fields)) <> "\n",
    )),
  )
}
