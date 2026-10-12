//// Short-lived data kept in memory only (never written to the state file):
//// login codes, OAuth authorization codes and pending consent requests,
//// legacy MCP session client info, one-time document upload and download
//// URLs, and
//// review-sweep bookkeeping. Losing it
//// on restart costs at most a re-sent login code or a repeated OAuth click.

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import huddy/model.{type DocRevision}

pub type LoginCode {
  LoginCode(
    code_hmac: String,
    expires_at: Int,
    attempts: Int,
    last_sent_at: Int,
  )
}

pub type AuthRequest {
  AuthRequest(
    user: Int,
    client_id: String,
    client_name: String,
    redirect_uri: String,
    code_challenge: String,
    state: String,
    scope: String,
    resource: String,
    expires_at: Int,
  )
}

pub type OAuthCode {
  OAuthCode(
    user: Int,
    client_id: String,
    redirect_uri: String,
    code_challenge: String,
    scope: String,
    resource: String,
    expires_at: Int,
  )
}

pub type McpSession {
  McpSession(client_name: String, protocol_version: String, expires_at: Int)
}

/// A one-time URL an agent can upload a document to (`huddy_doc_upload`
/// without content), keyed by the SHA-256 of its secret.
pub type DocUpload {
  DocUpload(
    agent: Int,
    title: Option(String),
    /// for a new document
    slug: Option(String),
    /// a new version of this document at this revision
    replaces: Option(DocRevision),
    expires_at: Int,
  )
}

/// A one-time URL to download a document's zip (`huddy_doc_download`),
/// keyed by the SHA-256 of its secret. It serves the revision it was issued
/// for, to the user it was issued to.
pub type DocDownload {
  DocDownload(user: Int, doc: DocRevision, expires_at: Int)
}

pub type Ephemeral {
  Ephemeral(
    login_codes: Dict(String, LoginCode),
    auth_requests: Dict(String, AuthRequest),
    oauth_codes: Dict(String, OAuthCode),
    mcp_sessions: Dict(String, McpSession),
    doc_uploads: Dict(String, DocUpload),
    doc_downloads: Dict(String, DocDownload),
    /// agent id -> time of the last review sweep of that agent
    swept: Dict(Int, Int),
  )
}

pub fn new() -> Ephemeral {
  Ephemeral(
    dict.new(),
    dict.new(),
    dict.new(),
    dict.new(),
    dict.new(),
    dict.new(),
    dict.new(),
  )
}

/// Drop everything that has expired.
pub fn expire(eph: Ephemeral, now: Int) -> Ephemeral {
  Ephemeral(
    ..eph,
    login_codes: dict.filter(eph.login_codes, fn(_, c) {
      c.expires_at > now || now - c.last_sent_at < 3_600_000
    }),
    auth_requests: dict.filter(eph.auth_requests, fn(_, r) {
      r.expires_at > now
    }),
    oauth_codes: dict.filter(eph.oauth_codes, fn(_, c) { c.expires_at > now }),
    mcp_sessions: dict.filter(eph.mcp_sessions, fn(_, s) { s.expires_at > now }),
    doc_uploads: dict.filter(eph.doc_uploads, fn(_, u) { u.expires_at > now }),
    doc_downloads: dict.filter(eph.doc_downloads, fn(_, d) {
      d.expires_at > now
    }),
  )
}
