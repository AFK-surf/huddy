//// Huddy: a heads-up display for a team's coding agents.
////
//// Usage: huddy [--config PATH]   (default: $HUDDY_CONFIG or ./huddy.json)

import argv
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import huddy/blob
import huddy/config.{type Config}
import huddy/ctx.{type Ctx, Ctx}
import huddy/doc_lock
import huddy/documents
import huddy/janitor
import huddy/jev
import huddy/mailer
import huddy/model
import huddy/oauth/cimd
import huddy/persist
import huddy/store
import huddy/sys
import huddy/web/router
import logging
import mist
import wisp

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)
  let path = config_path(argv.load().arguments)
  case config.load(path) {
    Error(e) -> fail(e)
    Ok(cfg) ->
      case start(cfg, default_overrides()) {
        Error(e) -> fail(e)
        Ok(_) -> {
          logging.log(
            logging.Notice,
            "huddy for " <> cfg.team_name <> " is up at " <> cfg.base_url,
          )
          process.sleep_forever()
        }
      }
  }
}

fn fail(message: String) -> Nil {
  io.println_error("huddy: " <> message)
  sys.halt(1)
}

fn config_path(args: List(String)) -> String {
  case args {
    ["--config", path, ..] | ["-c", path, ..] -> path
    [_, ..rest] -> config_path(rest)
    [] -> sys.getenv("HUDDY_CONFIG") |> result.unwrap("huddy.json")
  }
}

/// Hooks that tests replace.
pub type Overrides {
  Overrides(
    ask: Option(Option(jev.Ask)),
    send_email: Option(fn(String, String, String) -> Nil),
    fetch_client: Option(fn(String, Int) -> Result(model.OAuthClient, String)),
    static_dir: Option(String),
  )
}

pub fn default_overrides() -> Overrides {
  Overrides(None, None, None, None)
}

/// Start everything: load the state file, then supervise the
/// store, the janitor and the HTTP server.
pub fn start(cfg: Config, overrides: Overrides) -> Result(Ctx, String) {
  sys.limiter_init()
  documents.cache_init()
  case sys.configure_proxy() {
    Ok(proxy) -> logging.log(logging.Info, "outbound HTTPS via proxy " <> proxy)
    Error(_) -> Nil
  }
  let storage = cfg.storage
  use _ <- result.try(blob.ensure_dir(blob.parent(storage.path)))
  // Load once up front so a bad file fails startup with a clear message.
  use _ <- result.try(persist.load(storage.path, storage.backup_dir))
  let store_name = process.new_name("huddy_store")
  let store_subject = process.named_subject(store_name)
  let locks_name = process.new_name("huddy_doc_locks")
  let static_dir = case overrides.static_dir {
    Some(dir) -> dir
    None ->
      case wisp.priv_directory("huddy") {
        Ok(priv) -> priv <> "/static"
        Error(_) -> "priv/static"
      }
  }
  let ask = case overrides.ask {
    Some(ask) -> ask
    None ->
      case cfg.decision_model.enabled {
        True -> Some(jev.client(cfg.decision_model))
        False -> None
      }
  }
  let ctx =
    Ctx(
      config: cfg,
      store: store_subject,
      doc_locks: process.named_subject(locks_name),
      ask:,
      boot_id: sys.random_token(8),
      static_dir:,
      send_email: option.unwrap(overrides.send_email, mailer.sender(cfg)),
      fetch_client: option.unwrap(overrides.fetch_client, fn(url, now) {
        cimd.fetch(url, cfg.mcp.trusted_client_hosts, cimd.http_fetch, now)
      }),
    )
  let server =
    mist.new(router.handler(ctx))
    |> mist.bind(cfg.listen)
    |> mist.port(cfg.port)
    |> mist.after_start(fn(port, _, _) {
      logging.log(
        logging.Info,
        "listening on " <> cfg.listen <> ":" <> int.to_string(port),
      )
    })
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(
    supervision.worker(fn() {
      // The store (re)loads the state on every (re)start, in the background.
      store.start(
        cfg,
        fn() { persist.load(storage.path, storage.backup_dir) },
        store_name,
      )
    }),
  )
  |> supervisor.add(supervision.worker(fn() { doc_lock.start(locks_name) }))
  |> supervisor.add(supervision.worker(fn() { janitor.start(ctx) }))
  |> supervisor.add(mist.supervised(server))
  |> supervisor.start
  |> result.map(fn(_) { ctx })
  |> result.map_error(fn(e) {
    case e {
      actor.InitFailed(reason) -> reason
      actor.InitTimeout -> "startup timed out"
      actor.InitExited(_) -> "startup failed (is the port in use?)"
    }
  })
}
