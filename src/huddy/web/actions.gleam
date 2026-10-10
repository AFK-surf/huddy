//// Human actions on the board: mark a decision seen, hide and un-hide items.

import gleam/int
import gleam/result
import gleam/string
import huddy/ctx.{type Ctx}
import huddy/state
import huddy/store
import huddy/web/session
import wisp.{type Request, type Response}

pub fn handle(ctx: Ctx, req: Request, id: String, action: String) -> Response {
  use user <- session.require_user(ctx, req)
  case session.same_origin(ctx, req) {
    False -> wisp.bad_request("cross-origin request")
    True -> {
      use form <- wisp.require_form(req)
      let return_to = session.form_value(form, "return_to")
      case int.parse(id) {
        Error(_) -> wisp.not_found()
        Ok(item_id) -> {
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
