//// The board page (§9.2). Rendered completely on the server as a set of
//// zones; the SSE stream re-sends zones whose HTML changed.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import huddy/ctx.{type Ctx}
import huddy/fmt
import huddy/model.{type User}
import huddy/rank.{type ItemView, type View}
import huddy/state
import huddy/store
import huddy/sys
import huddy/web/html.{type Node}
import huddy/web/sketch

pub type Board {
  Board(
    view: View,
    viewer: User,
    unseen: Int,
    storage_error: Option(String),
    tokens_month: Int,
    comment_max_chars: Int,
    now: Int,
  )
}

pub fn load(ctx: Ctx, viewer: User, filters: rank.Filters) -> Board {
  let now = sys.now_ms()
  let view = store.view(ctx.store, filters)
  let month_start = now - 30 * 86_400_000
  let #(unseen, tokens) =
    store.read(ctx.store, fn(s, _) {
      #(
        rank.unseen_decisions_for(s, viewer.id),
        state.tokens_since(s, month_start),
      )
    })
  Board(
    view:,
    viewer:,
    unseen:,
    storage_error: store.status(ctx.store),
    tokens_month: tokens,
    comment_max_chars: ctx.config.limits.comment_max_chars,
    now:,
  )
}

pub fn filters_from_query(query: List(#(String, String))) -> rank.Filters {
  let get = fn(name) {
    case list.key_find(query, name) {
      Ok("") | Error(_) -> None
      Ok(v) -> Some(v)
    }
  }
  rank.Filters(
    owner: get("owner"),
    project: get("project"),
    name: get("name"),
    expand: get("expand"),
    hide_away: get("away") != Some("show"),
  )
}

fn query_string(filters: rank.Filters) -> String {
  let pairs =
    [
      #("owner", filters.owner),
      #("project", filters.project),
      #("name", filters.name),
      #("expand", filters.expand),
      #("away", case filters.hide_away {
        True -> None
        False -> Some("show")
      }),
    ]
    |> list.filter_map(fn(p) {
      case p.1 {
        Some(v) -> Ok(#(p.0, v))
        None -> Error(Nil)
      }
    })
  case pairs {
    [] -> ""
    _ -> "?" <> uri.query_to_string(pairs)
  }
}

fn with_expand(filters: rank.Filters, zone: Option(String)) -> String {
  "/" <> query_string(rank.Filters(..filters, expand: zone))
}

/// The full page.
pub fn render(ctx: Ctx, board: Board) -> String {
  let title = case board.unseen {
    0 -> "Huddy · " <> ctx.config.team_name
    n -> "(" <> int.to_string(n) <> ") Huddy · " <> ctx.config.team_name
  }
  let #(footer, rest) =
    zones(ctx, board) |> list.partition(fn(z) { z.0 == "zone-footer" })
  let raw = fn(zs: List(#(String, String))) {
    list.map(zs, fn(z) { html.raw(z.1) })
  }
  html.document(
    title,
    [html.el("script", [#("src", "/static/huddy.js"), #("defer", "")], [])],
    [
      html.div(
        [
          html.class("board"),
          #("data-boot", ctx.boot_id),
          #("data-events", "/events" <> query_string(board.view.filters)),
        ],
        list.flatten([raw(rest), [legend()], raw(footer)]),
      ),
    ],
  )
}

/// The page's zones as (element id, HTML), in page order.
pub fn zones(ctx: Ctx, board: Board) -> List(#(String, String)) {
  let expand = option.unwrap(board.view.filters.expand, "")
  [
    #("zone-header", header(ctx, board)),
    #("zone-agents", agents(board)),
    #("zone-decisions", decisions(board)),
    #("zone-cols", columns(board)),
    #("zone-hidden", case expand {
      "hidden" -> hidden(board)
      _ -> html.to_string(html.el("section", [html.id("zone-hidden")], []))
    }),
    #("zone-footer", footer(ctx, board)),
  ]
}

// --- header & agents -------------------------------------------------------------

fn header(ctx: Ctx, board: Board) -> String {
  let v = board.view
  let blocked = list.length(v.blocking)
  html.to_string(
    html.el("header", [html.id("zone-header"), html.class("top")], [
      html.el("h1", [], [html.a("/", [], [html.text("Huddy")])]),
      html.span([html.class("team")], [html.text(ctx.config.team_name)]),
      html.div([html.class("stats")], [
        html.span([], [html.text(plural(list.length(v.agents), "agent"))]),
        html.when(blocked > 0, fn() {
          html.span([html.class("blk")], [
            html.text(int.to_string(blocked) <> " blocked"),
          ])
        }),
        html.span([html.class("live"), html.id("live")], [html.text("live")]),
        html.when(ctx.config.notify.browser, fn() {
          html.el(
            "button",
            [
              html.class("linkish"),
              html.id("notify-toggle"),
              #("type", "button"),
              #("hidden", ""),
            ],
            [html.text("🔔 notify me")],
          )
        }),
        html.a("/docs", [], [html.text("docs")]),
        html.a("/settings", [], [html.text("you: " <> board.viewer.handle)]),
      ]),
      html.span(
        [
          html.id("count"),
          #("data-count", int.to_string(board.unseen)),
          #("hidden", ""),
        ],
        [],
      ),
      case board.storage_error {
        Some(e) ->
          html.div([html.class("banner")], [
            html.text(
              "Storage error — changes are kept in memory and retried: " <> e,
            ),
          ])
        None -> html.none()
      },
    ]),
  )
}

fn plural(n: Int, word: String) -> String {
  int.to_string(n)
  <> " "
  <> word
  <> case n {
    1 -> ""
    _ -> "s"
  }
}

fn agents(board: Board) -> String {
  let f = board.view.filters
  let filtered = f.owner != None || f.project != None || f.name != None
  html.to_string(html.el(
    "nav",
    [html.id("zone-agents"), html.class("agents"), #("aria-label", "Agents")],
    list.flatten([
      list.map(board.view.agents, fn(a) {
        let href =
          "/"
          <> query_string(
            rank.Filters(
              ..f,
              owner: Some(a.owner_handle),
              project: Some(a.agent.project),
              name: Some(a.agent.name),
              expand: None,
            ),
          )
        html.a(
          href,
          [
            html.class(
              "chip sk"
              <> case a.away {
                True -> " away"
                False -> ""
              },
            ),
          ],
          [
            html.raw(sketch.frame(
              "chip:" <> a.label,
              sketch.Rect,
              200,
              28,
              "ink",
              None,
            )),
            html.span([html.class("dot")], []),
            html.text(a.label),
            html.when(a.away, fn() { html.text(" · away") }),
          ],
        )
      }),
      [
        html.when(filtered, fn() {
          html.a(
            "/"
              <> query_string(
              rank.Filters(..rank.no_filters(), hide_away: f.hide_away),
            ),
            [html.class("clear")],
            [html.text("× show everyone")],
          )
        }),
        html.when(
          f.hide_away || list.any(board.view.agents, fn(a) { a.away }),
          fn() {
            html.a(
              "/" <> query_string(rank.Filters(..f, hide_away: !f.hide_away)),
              [html.class("clear")],
              [
                html.text(case f.hide_away {
                  True -> "show away agents"
                  False -> "hide away agents"
                }),
              ],
            )
          },
        ),
        html.when(board.view.agents == [], fn() {
          html.span([html.class("muted")], [
            html.text(case f.hide_away {
              True -> "No active agents. Connect one from "
              False -> "No agents yet. Connect one from "
            }),
            html.a("/settings", [], [html.text("settings")]),
            html.text("."),
          ])
        }),
      ],
    ]),
  ))
}

// --- decisions -------------------------------------------------------------------

fn icon(kind: sketch.Icon, seed: String) -> Node {
  html.raw(sketch.icon(kind, seed))
}

fn decisions(board: Board) -> String {
  let v = board.view
  let all = list.append(v.blocking, v.decisions)
  let mine = list.count(all, fn(d) { d.owner == board.viewer.id })
  html.to_string(
    html.el("section", [html.id("zone-decisions"), html.class("zone")], [
      html.el("h2", [], [
        icon(sketch.DecisionIcon(True), "h-d"),
        html.text("Needs a human "),
        html.el("small", [], [
          html.text(
            int.to_string(list.length(all) + v.decisions_more)
            <> " open"
            <> case mine {
              0 -> ""
              n -> " · " <> int.to_string(n) <> " yours"
            },
          ),
        ]),
      ]),
      case all {
        [] ->
          html.el("p", [html.class("muted")], [
            html.text("Nothing needs a human right now."),
          ])
        _ ->
          html.div(
            [html.class("decisions")],
            list.map(all, decision_card(board, _)),
          )
      },
      more(v.decisions_more, "decisions", v.filters),
      html.when(all != [], fn() {
        html.div([html.class("hint")], [
          html.text(
            "Answer here or in the agent's session. Answers reach the agent with its next Huddy call; it marks the decision resolved.",
          ),
        ])
      }),
    ]),
  )
}

fn seed(v: ItemView) -> String {
  model.item_ref(v.item.id) <> ":" <> int.to_string(v.item.version)
}

fn decision_card(board: Board, v: ItemView) -> Node {
  let item = v.item
  let yours = v.owner == board.viewer.id
  let s = seed(v)
  html.el("article", [html.class("card sk"), html.id(model.item_ref(item.id))], [
    html.raw(
      sketch.frame(
        s,
        sketch.Rect,
        280,
        200,
        case item.blocking {
          True -> "dec"
          False -> "ink"
        },
        case item.blocking {
          True -> Some("dec-bg")
          False -> None
        },
      ),
    ),
    case item.blocking {
      True ->
        html.span([html.class("tag sk")], [
          html.raw(sketch.frame(s <> ":tag", sketch.Rect, 90, 24, "red", None)),
          html.text("BLOCKED"),
        ])
      False ->
        html.span([html.class("ic")], [icon(sketch.DecisionIcon(False), s)])
    },
    html.div([html.class("title")], [html.text(item.title)]),
    html.div([html.class("meta")], [
      html.text(
        v.agent_label <> " · waiting " <> fmt.age(board.now, item.created_at),
      ),
      html.when(yours, fn() {
        html.span([html.class("yours")], [html.text(" · yours")])
      }),
      html.when(v.away, fn() { html.text(" · agent away") }),
    ]),
    detail(item.detail, "detail"),
    case item.options {
      [] -> html.none()
      opts ->
        html.div([html.class("options")], [
          html.el("b", [], [html.text("options: ")]),
          html.text(string.join(opts, " · ")),
        ])
    },
    flags(v),
    thread(board, v, 3),
    html.div([html.class("opts")], [
      case v.answered, v.seen_by {
        Some(#(who, at)), _ ->
          html.span([html.class("seen")], [
            html.text("answered by " <> who <> " · " <> fmt.age(board.now, at)),
          ])
        None, Some(who) ->
          html.span([html.class("seen")], [
            html.text(
              "seen by "
              <> who
              <> " · "
              <> fmt.age(board.now, option.unwrap(item.seen_at, board.now)),
            ),
          ])
        None, None ->
          html.post_form(
            "/items/" <> int.to_string(item.id) <> "/seen",
            [#("data-fetch", "")],
            [#("return_to", "/" <> query_string(board.view.filters))],
            [
              html.el("button", [html.class("btn sk"), #("type", "submit")], [
                html.raw(sketch.frame(
                  s <> ":seen",
                  sketch.Rect,
                  70,
                  28,
                  "ink",
                  None,
                )),
                html.text("seen"),
              ]),
            ],
          )
      },
      comment_control(board, v, []),
      hide_control(board, v),
    ]),
  ])
}

/// The item's most recent `show` comments; older ones behind a toggle.
fn thread(board: Board, v: ItemView, show: Int) -> Node {
  case v.comments {
    [] -> html.none()
    comments -> {
      let #(earlier, recent) =
        list.split(comments, int.max(list.length(comments) - show, 0))
      html.div([html.class("thread")], [
        case earlier {
          [] -> html.none()
          _ ->
            html.el("details", [html.class("earlier")], [
              html.el("summary", [], [
                html.text(int.to_string(list.length(earlier)) <> " earlier"),
              ]),
              html.fragment(list.map(earlier, comment_line(board, _))),
            ])
        },
        html.fragment(list.map(recent, comment_line(board, _))),
      ])
    }
  }
}

fn comment_line(board: Board, cv: rank.CommentView) -> Node {
  let c = cv.comment
  html.div(
    [
      html.class(case cv.by_agent {
        True -> "cm agent"
        False -> "cm"
      }),
      html.id(model.comment_ref(c.id)),
    ],
    [
      html.el("b", [], [html.text(cv.author)]),
      case c.pick {
        Some(p) -> html.text(" picked " <> fmt.quote(p))
        None -> html.none()
      },
      html.span([html.class("age")], [
        html.text(" · " <> fmt.age(board.now, c.created_at)),
      ]),
      case c.body {
        "" -> html.none()
        b -> html.fragment([html.text(": "), html.fragment(linkify(b))])
      },
      case cv.by_agent {
        True -> html.none()
        False ->
          html.span([html.class("receipt")], [
            html.text(case c.acked_at, c.sent_at {
              Some(at), _ -> "✓ acknowledged " <> fmt.ago(board.now, at)
              None, Some(at) ->
                "sent " <> fmt.ago(board.now, at) <> " · not acknowledged"
              None, None -> "⧗ waits for the agent's next Huddy call"
            }),
          ])
      },
    ],
  )
}

/// "comment" (or "answer" on a decision): a note for the item's agent.
/// Decisions with options get one button per option. `also` names other
/// goals that get the same comment (a merged goal rectangle).
fn comment_control(board: Board, v: ItemView, also: List(Int)) -> Node {
  let item = v.item
  let decision = item.kind == model.Decision
  html.el("details", [html.class("comment")], [
    html.el("summary", [], [
      html.text(case decision {
        True -> "answer"
        False -> "comment"
      }),
    ]),
    html.post_form(
      "/items/" <> int.to_string(item.id) <> "/comment",
      [#("data-fetch", ""), #("data-reset", "")],
      [
        #("return_to", "/" <> query_string(board.view.filters)),
        ..list.map(also, fn(id) { #("also", model.item_ref(id)) })
      ],
      [
        case decision, item.options {
          True, [_, ..] as options ->
            html.div(
              [html.class("picks")],
              list.map(options, fn(o) {
                html.el(
                  "button",
                  [
                    html.class("pick"),
                    #("type", "submit"),
                    #("name", "pick"),
                    #("value", o),
                  ],
                  [html.text(o)],
                )
              }),
            )
          _, _ -> html.none()
        },
        html.el(
          "textarea",
          [
            #("name", "body"),
            #("rows", "2"),
            #("maxlength", int.to_string(board.comment_max_chars)),
            #("placeholder", case decision {
              True -> "your answer, or a note with the pick"
              False -> "a comment for the agent"
            }),
          ],
          [],
        ),
        html.el("button", [html.class("linkish"), #("type", "submit")], [
          html.text("send"),
        ]),
      ],
    ),
  ])
}

fn hide_control(board: Board, v: ItemView) -> Node {
  html.el("details", [html.class("hide")], [
    html.el("summary", [], [html.text("hide")]),
    html.post_form(
      "/items/" <> int.to_string(v.item.id) <> "/hide",
      [#("data-fetch", "")],
      [#("return_to", "/" <> query_string(board.view.filters))],
      [
        html.el(
          "input",
          [
            #("name", "note"),
            #("placeholder", "note for the agent (optional)"),
            #("maxlength", "200"),
          ],
          [],
        ),
        html.el("button", [html.class("linkish"), #("type", "submit")], [
          html.text("hide it"),
        ]),
      ],
    ),
  ])
}

fn flags(v: ItemView) -> Node {
  html.fragment([
    doc_links(v),
    case v.overlap {
      Some(#(id, title, label)) ->
        html.div([html.class("sub")], [
          html.span([html.class("overlap")], [html.text("≈ overlaps ")]),
          html.a("#" <> model.item_ref(id), [], [html.text(fmt.quote(title))]),
          html.text(" · " <> label),
        ])
      None -> html.none()
    },
    case v.item.stale_p {
      Some(_) ->
        html.div([html.class("sub")], [
          html.text("? may be outdated — its agent has been told"),
        ])
      None -> html.none()
    },
  ])
}

/// Links to the item's documents.
fn doc_links(v: ItemView) -> Node {
  case v.docs {
    [] -> html.none()
    docs ->
      html.div(
        [html.class("docs")],
        list.map(docs, fn(d) {
          let ref = d.0
          html.a("/docs/" <> ref, [html.class("doclink")], [
            icon(sketch.DocIcon, ref),
            html.text(d.1),
          ])
        }),
      )
  }
}

fn detail(text: String, cls: String) -> Node {
  case string.trim(text) {
    "" -> html.none()
    t ->
      case string.length(t) > 240 {
        False -> html.div([html.class(cls)], linkify(t))
        True ->
          html.el("details", [html.class(cls)], [
            html.el("summary", [], [html.text(fmt.clip(t, 200))]),
            html.div([], linkify(t)),
          ])
      }
  }
}

/// Text with http(s) URLs turned into links; everything else escaped.
pub fn linkify(text: String) -> List(Node) {
  text
  |> string.split(" ")
  |> list.map(fn(word) {
    case
      string.starts_with(word, "https://")
      || string.starts_with(word, "http://")
    {
      True ->
        html.a(word, [#("rel", "noopener nofollow"), #("target", "_blank")], [
          html.text(word),
        ])
      False -> html.text(word)
    }
  })
  |> list.intersperse(html.text(" "))
}

fn more(n: Int, zone: String, filters: rank.Filters) -> Node {
  case n > 0, filters.expand {
    True, _ ->
      html.div([html.class("more")], [
        html.a(with_expand(filters, Some(zone)), [], [
          html.text("+" <> int.to_string(n) <> " more " <> zone),
        ]),
      ])
    False, Some(e) if e == zone ->
      html.div([html.class("more")], [
        html.a(with_expand(filters, None), [], [html.text("show fewer")]),
      ])
    False, _ -> html.none()
  }
}

// --- goals & tasks ---------------------------------------------------------------

fn columns(board: Board) -> String {
  let v = board.view
  html.to_string(
    html.div([html.id("zone-cols"), html.class("cols")], [
      html.el("section", [html.class("zone")], [
        html.el("h2", [], [icon(sketch.GoalIcon, "h-g"), html.text("Goals")]),
        case v.goals {
          [] ->
            html.el("p", [html.class("muted")], [html.text("No goals yet.")])
          goals ->
            html.div([html.class("goals")], list.map(goals, goal(board, _)))
        },
        more(v.goals_more, "goals", v.filters),
      ]),
      html.el("section", [html.class("zone")], [
        html.el("h2", [], [
          icon(sketch.TaskIcon, "h-t"),
          html.text("Tasks "),
          html.el("small", [], [
            html.text(
              int.to_string(list.length(v.tasks))
              <> " of "
              <> int.to_string(list.length(v.tasks) + v.tasks_more),
            ),
          ]),
        ]),
        case v.tasks {
          [] ->
            html.el("p", [html.class("muted")], [html.text("No open tasks.")])
          tasks ->
            html.div([html.class("tasks")], list.map(tasks, task(board, _)))
        },
        more(v.tasks_more, "tasks", v.filters),
      ]),
    ]),
  )
}

fn goal(board: Board, g: rank.GoalGroup) -> Node {
  let p = g.primary
  html.div([html.class("goal"), html.id(model.item_ref(p.item.id))], [
    html.div([html.class("bubble sk")], [
      html.raw(sketch.frame(seed(p), sketch.Rect, 320, 90, "goal", None)),
      html.text(p.item.title),
      doc_links(p),
    ]),
    html.div(
      [html.class("who")],
      list.map([p, ..g.others], fn(v) {
        html.span(
          [
            html.class(case v.away {
              True -> "away"
              False -> ""
            }),
          ],
          [
            html.text(
              v.agent_label
              <> case v.away {
                True -> " (away)"
                False -> ""
              },
            ),
          ],
        )
      }),
    ),
    thread(board, p, 2),
    comment_control(board, p, list.map(g.others, fn(o) { o.item.id })),
  ])
}

fn importance_label(item: model.Item) -> Option(String) {
  case item.importance {
    Some(i) if i >=. 2.5 -> Some("critical")
    Some(i) if i >=. 1.7 -> Some("notable")
    _ -> None
  }
}

fn task(board: Board, v: ItemView) -> Node {
  let item = v.item
  let stale = option.is_some(item.stale_p)
  html.div(
    [
      html.class(
        "task"
        <> case stale {
          True -> " stale"
          False -> ""
        },
      ),
      html.id(model.item_ref(item.id)),
    ],
    [
      icon(sketch.TaskIcon, seed(v)),
      html.div([], [
        html.div([html.class("t")], [html.text(item.title)]),
        case importance_label(item) {
          Some(l) -> html.div([html.class("sub")], [html.text(l)])
          None -> html.none()
        },
        detail(item.detail, "sub"),
        flags(v),
        thread(board, v, 2),
      ]),
      html.div([html.class("side")], [
        html.span([html.class("meta")], [
          html.text(
            v.agent_label <> " · " <> fmt.age(board.now, item.updated_at),
          ),
        ]),
        comment_control(board, v, []),
        hide_control(board, v),
      ]),
    ],
  )
}

fn hidden(board: Board) -> String {
  html.to_string(
    html.el("section", [html.id("zone-hidden"), html.class("zone")], [
      html.el("h2", [], [html.text("Hidden by humans")]),
      case board.view.hidden {
        [] ->
          html.el("p", [html.class("muted")], [html.text("Nothing is hidden.")])
        items ->
          html.div(
            [html.class("tasks")],
            list.map(items, fn(v) {
              html.div([html.class("task")], [
                icon(
                  case v.item.kind {
                    model.Goal -> sketch.GoalIcon
                    model.Task -> sketch.TaskIcon
                    model.Decision -> sketch.DecisionIcon(v.item.blocking)
                  },
                  seed(v),
                ),
                html.div([], [
                  html.div([html.class("t")], [html.text(v.item.title)]),
                  html.div([html.class("sub")], [
                    html.text(
                      "hidden by "
                      <> option.unwrap(v.hidden_by, "?")
                      <> case v.item.hidden_note {
                        Some(n) -> ": " <> fmt.quote(n)
                        None -> ""
                      },
                    ),
                  ]),
                  thread(board, v, 2),
                ]),
                html.div([html.class("side")], [
                  html.span([html.class("meta")], [html.text(v.agent_label)]),
                  html.post_form(
                    "/items/" <> int.to_string(v.item.id) <> "/unhide",
                    [#("data-fetch", "")],
                    [#("return_to", "/" <> query_string(board.view.filters))],
                    [
                      html.el(
                        "button",
                        [html.class("linkish"), #("type", "submit")],
                        [html.text("un-hide")],
                      ),
                    ],
                  ),
                ]),
              ])
            }),
          )
      },
    ]),
  )
}

// --- footer & legend -------------------------------------------------------------

fn footer(ctx: Ctx, board: Board) -> String {
  let hidden_count = list.length(board.view.hidden)
  html.to_string(
    html.el("footer", [html.id("zone-footer")], [
      html.when(ctx.config.decision_model.enabled, fn() {
        html.span([], [
          html.text(
            "decision model: "
            <> tokens(board.tokens_month)
            <> " tokens in 30 days",
          ),
        ])
      }),
      html.when(hidden_count > 0, fn() {
        html.a(with_expand(board.view.filters, Some("hidden")), [], [
          html.text(int.to_string(hidden_count) <> " hidden"),
        ])
      }),
      html.a("/settings", [], [html.text("settings")]),
      html.post_form("/logout", [html.class("inline")], [], [
        html.el("button", [html.class("linkish"), #("type", "submit")], [
          html.text("sign out"),
        ]),
      ]),
    ]),
  )
}

fn tokens(n: Int) -> String {
  case n >= 1000 {
    True -> float.to_string(int.to_float(n / 100) /. 10.0) <> "k"
    False -> int.to_string(n)
  }
}

fn legend() -> Node {
  html.div([html.class("legend")], [
    html.span([], [icon(sketch.GoalIcon, "l1"), html.text("goal")]),
    html.span([], [icon(sketch.TaskIcon, "l2"), html.text("task")]),
    html.span([], [
      icon(sketch.DecisionIcon(True), "l3"),
      html.text("blocking decision"),
    ]),
    html.span([], [
      icon(sketch.DecisionIcon(False), "l4"),
      html.text("non-blocking decision"),
    ]),
    html.span([html.class("faded")], [html.text("faded = may be outdated")]),
    html.span([], [html.text("≈ = overlapping work")]),
  ])
}
