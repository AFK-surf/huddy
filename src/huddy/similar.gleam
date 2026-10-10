//// In-memory similarity for duplicate/overlap candidates: character-trigram
//// Jaccard over title and detail. There are at most a few hundred open
//// items, so a linear scan is fast enough and needs no index.

import gleam/float
import gleam/int
import gleam/list
import gleam/order
import gleam/set.{type Set}
import gleam/string

pub fn trigrams(text: String) -> Set(String) {
  text
  |> string.lowercase
  |> string.to_graphemes
  |> list.map(fn(c) {
    case is_word_char(c) {
      True -> c
      False -> " "
    }
  })
  |> string.concat
  |> string.split(" ")
  |> list.filter(fn(w) { string.length(w) > 1 })
  |> list.flat_map(fn(word) {
    let padded = " " <> word <> " "
    let chars = string.to_graphemes(padded)
    list.window(chars, 3) |> list.map(string.concat)
  })
  |> set.from_list
}

fn is_word_char(c: String) -> Bool {
  case string.to_utf_codepoints(c) {
    [cp] -> {
      let n = string.utf_codepoint_to_int(cp)
      { n >= 97 && n <= 122 } || { n >= 48 && n <= 57 } || n > 127
    }
    _ -> False
  }
}

pub fn jaccard(a: Set(String), b: Set(String)) -> Float {
  let union = set.size(set.union(a, b))
  case union {
    0 -> 0.0
    _ -> int.to_float(set.size(set.intersection(a, b))) /. int.to_float(union)
  }
}

/// Rank `candidates` by similarity to `text`, adding `bonus(c)` (e.g. for the
/// same project), keeping those above `min_score`, best first, at most `limit`.
pub fn top(
  text: String,
  candidates: List(a),
  text_of: fn(a) -> String,
  bonus: fn(a) -> Float,
  min_score: Float,
  limit: Int,
) -> List(a) {
  let target = trigrams(text)
  candidates
  |> list.map(fn(c) { #(c, jaccard(target, trigrams(text_of(c)))) })
  |> list.filter(fn(pair) { pair.1 >=. min_score })
  |> list.map(fn(pair) { #(pair.0, pair.1 +. bonus(pair.0)) })
  |> list.sort(fn(a, b) {
    case float.compare(b.1, a.1) {
      order.Eq -> order.Eq
      o -> o
    }
  })
  |> list.take(limit)
  |> list.map(fn(pair) { pair.0 })
}
