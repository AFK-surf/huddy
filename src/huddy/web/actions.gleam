//// Human actions on the board: mark a decision seen, hide and un-hide items,
//// comment on an item or answer a decision.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import huddy/ctx.{type Ctx}
import huddy/model
import huddy/state
import huddy/store
import huddy/sys
import huddy/web/session
import wisp.{type Request, type Response}

pub fn handle(ctx: Ctx, req: Request, id: String, action: String) -> Response {
  use user <- session.require_user(ctx, req)
  case session.same_origin(ctx, req) {
    False -> wisp.bad_request("cross-origin request")
    True -> {
      use form <- wisp.require_form(req)
      let return_to = session.form_value(form, "return_to")
      case int.parse(id), action {
        Error(_), _ -> wisp.not_found()
        Ok(item_id), "comment" ->
          case
            sys.rate_limit(
              "web-comment:" <> int.to_string(user.id),
              ctx.config.limits.comments_per_user_per_minute,
              60_000,
            )
          {
            False ->
              wisp.response(429)
              |> wisp.string_body("Too many comments; try again in a minute.")
            True -> comment(ctx, req, form, user.id, item_id, return_to)
          }
        Ok(item_id), _ -> {
          let result =
            store.update(ctx.store, fn(s, e, now) {
              let applied = case action {
                "seen" -> state.mark_seen(s, item_id, user.id, now)
                "hide" ->
                  state.hide(
                    s,
                    item_id,
                    user.id,
                    string.slice(session.form_value(form, "note"), 0, 200),
                    now,
                  )
                "unhide" -> state.unhide(s, item_id, user.id, now)
                _ -> Error("unknown action")
              }
              case applied {
                Ok(s) -> store.Changed(s, e, [store.Publish], Ok(Nil))
                Error(reason) -> store.NoChange(Error(reason))
              }
            })
            |> result.flatten
          case result {
            Ok(_) -> session.done(req, return_to)
            Error(reason) -> wisp.bad_request(reason)
          }
        }
      }
    }
  }
}

/// Add a comment (or a decision answer: `pick`) to the item. A goal
/// rectangle that merges several agents' goals also names the others in
/// `also`, so each agent gets the comment on its own goal. All or nothing.
fn comment(
  ctx: Ctx,
  req: Request,
  form: wisp.FormData,
  user_id: Int,
  item_id: Int,
  return_to: String,
) -> Response {
  let body = session.form_value(form, "body")
  let pick = case session.form_value(form, "pick") {
    "" -> None
    p -> Some(p)
  }
  let also =
    form.values
    |> list.filter_map(fn(pair) {
      case pair.0 {
        "also" -> model.parse_ref(pair.1, "i")
        _ -> Error(Nil)
      }
    })
    |> list.filter(fn(id) { id != item_id })
    |> list.unique
  let limits =
    state.CommentLimits(
      max_chars: ctx.config.limits.comment_max_chars,
      per_item: ctx.config.limits.comments_per_item,
    )
  let result =
    store.update(ctx.store, fn(s, e, now) {
      let applied =
        state.add_comment(
          s,
          item_id,
          model.HumanAuthor(user_id),
          body,
          pick,
          limits,
          now,
        )
        |> result.try(fn(pair) {
          list.try_fold(also, pair.0, fn(s, other) {
            case state.get_item(s, other) {
              Some(i) if i.kind == model.Goal ->
                state.add_comment(
                  s,
                  other,
                  model.HumanAuthor(user_id),
                  body,
                  None,
                  limits,
                  now,
                )
                |> result.map(fn(p) { p.0 })
              _ -> Error("Only goals take a comment together.")
            }
          })
        })
      case applied {
        Ok(s) -> store.Changed(s, e, [store.Publish], Ok(Nil))
        Error(reason) -> store.NoChange(Error(reason))
      }
    })
    |> result.flatten
  case result {
    Ok(_) -> session.done(req, return_to)
    Error(reason) -> wisp.bad_request(reason)
  }
}
