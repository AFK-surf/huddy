//// Small formatting helpers shared by the web UI, MCP output and e-mails.

import gleam/float
import gleam/int
import gleam/string

/// "just now", "5m", "3h", "2d".
pub fn age(now: Int, then: Int) -> String {
  let s = int.max(now - then, 0) / 1000
  case s {
    _ if s < 60 -> "just now"
    _ if s < 3600 -> int.to_string(s / 60) <> "m"
    _ if s < 86_400 -> int.to_string(s / 3600) <> "h"
    _ -> int.to_string(s / 86_400) <> "d"
  }
}

pub fn prob(p: Float) -> String {
  float.to_string(int.to_float(float.round(p *. 100.0)) /. 100.0)
}

pub fn quote(text: String) -> String {
  "\"" <> text <> "\""
}

/// Truncate to `n` graphemes, adding an ellipsis when cut.
pub fn clip(text: String, n: Int) -> String {
  case string.length(text) > n {
    True -> string.slice(text, 0, n - 1) <> "…"
    False -> text
  }
}

/// "just now", "5m ago", "3h ago".
pub fn ago(now: Int, then: Int) -> String {
  case age(now, then) {
    "just now" -> "just now"
    a -> a <> " ago"
  }
}
