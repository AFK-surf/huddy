//// The application context passed to request handlers and background jobs.

import gleam/option.{type Option}
import huddy/config.{type Config}
import huddy/doc_lock
import huddy/jev
import huddy/model
import huddy/store.{type Store}

pub type Ctx {
  Ctx(
    config: Config,
    store: Store,
    /// serializes changes to each document
    doc_locks: doc_lock.Locks,
    /// None when the decision model is disabled.
    ask: Option(jev.Ask),
    /// Changes on every boot; clients reload when it differs.
    boot_id: String,
    /// Directory holding static assets.
    static_dir: String,
    /// Sends an e-mail (to, subject, body); replaced by a recorder in tests.
    send_email: fn(String, String, String) -> Nil,
    /// Fetches and validates an OAuth Client ID Metadata Document (url, now);
    /// replaced by a stub in tests.
    fetch_client: fn(String, Int) -> Result(model.OAuthClient, String),
  )
}
