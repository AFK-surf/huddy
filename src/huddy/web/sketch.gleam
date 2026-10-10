//// Hand-drawn (Excalidraw-like) shapes as inline SVG, generated on the
//// server. A small port of rough.js's core idea: every line is drawn twice
//// with slight bowing and endpoint jitter, ellipses overshoot, and fills are
//// hachure lines clipped to the shape.
////
//// The jitter is seeded from a string (item id + version), so a shape is
//// identical on every render and SSE swaps never make it wobble.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// --- deterministic PRNG (xorshift32) -------------------------------------------

pub opaque type Rng {
  Rng(Int)
}

const mask = 0xFFFFFFFF

pub fn seed(text: String) -> Rng {
  // FNV-1a over the UTF-8 bytes
  let h =
    text
    |> string.to_utf_codepoints
    |> list.fold(2_166_136_261, fn(h, cp) {
      int.bitwise_and(
        int.bitwise_exclusive_or(h, string.utf_codepoint_to_int(cp)) * 16_777_619,
        mask,
      )
    })
  case h {
    0 -> Rng(1)
    _ -> Rng(h)
  }
}

fn next(rng: Rng) -> #(Float, Rng) {
  let Rng(s) = rng
  let s = int.bitwise_and(int.bitwise_exclusive_or(s, int.bitwise_shift_left(s, 13)), mask)
  let s = int.bitwise_exclusive_or(s, int.bitwise_shift_right(s, 17))
  let s = int.bitwise_and(int.bitwise_exclusive_or(s, int.bitwise_shift_left(s, 5)), mask)
  #(int.to_float(s) /. 4_294_967_296.0, Rng(s))
}

/// A uniform value in [-1, 1).
fn signed(rng: Rng) -> #(Float, Rng) {
  let #(x, rng) = next(rng)
  #({ x -. 0.5 } *. 2.0, rng)
}

fn f(x: Float) -> String {
  let rounded = int.to_float(float.round(x *. 10.0)) /. 10.0
  float.to_string(rounded)
}

// --- primitives -------------------------------------------------------------------

/// A rough line: two quadratic strokes with jitter.
pub fn line(rng: Rng, x1: Float, y1: Float, x2: Float, y2: Float, k: Float) -> #(String, Rng) {
  let dx = x2 -. x1
  let dy = y2 -. y1
  let len = case float.square_root(dx *. dx +. dy *. dy) {
    Ok(l) if l >. 0.0 -> l
    _ -> 1.0
  }
  let off = float.min(0.5 +. len *. 0.012, 2.4) *. k
  let pass = fn(rng) {
    let #(b, rng) = signed(rng)
    let bow = b *. 0.5 *. float.min(len *. 0.03, 6.0) *. k
    let #(j1, rng) = signed(rng)
    let #(j2, rng) = signed(rng)
    let #(j3, rng) = signed(rng)
    let #(j4, rng) = signed(rng)
    let #(j5, rng) = signed(rng)
    let #(j6, rng) = signed(rng)
    let mx = { x1 +. x2 } /. 2.0 -. dy /. len *. bow +. j5 *. off *. 0.5
    let my = { y1 +. y2 } /. 2.0 +. dx /. len *. bow +. j6 *. off *. 0.5
    #(
      "M"
        <> f(x1 +. j1 *. off)
        <> " "
        <> f(y1 +. j2 *. off)
        <> "Q"
        <> f(mx)
        <> " "
        <> f(my)
        <> " "
        <> f(x2 +. j3 *. off)
        <> " "
        <> f(y2 +. j4 *. off),
      rng,
    )
  }
  let #(a, rng) = pass(rng)
  let #(b, rng) = pass(rng)
  #(a <> b, rng)
}

pub fn polygon(rng: Rng, points: List(#(Float, Float)), k: Float) -> #(String, Rng) {
  let closed = case points {
    [first, ..] -> list.append(points, [first])
    [] -> []
  }
  list.window_by_2(closed)
  |> list.fold(#("", rng), fn(acc, seg) {
    let #(d, rng) = acc
    let #(#(x1, y1), #(x2, y2)) = seg
    let #(l, rng) = line(rng, x1, y1, x2, y2, k)
    #(d <> l, rng)
  })
}

const tau = 6.283185307179586

fn cos(x: Float) -> Float {
  erl_cos(x)
}

fn sin(x: Float) -> Float {
  erl_sin(x)
}

@external(erlang, "math", "cos")
fn erl_cos(x: Float) -> Float

@external(erlang, "math", "sin")
fn erl_sin(x: Float) -> Float

/// A rough ellipse: two overshooting passes, smoothed with Catmull-Rom.
pub fn ellipse(rng: Rng, cx: Float, cy: Float, rx: Float, ry: Float, k: Float) -> #(String, Rng) {
  let pass = fn(rng) {
    let n = 14
    let #(s, rng) = next(rng)
    let start = s *. tau
    let #(o, rng) = next(rng)
    let over = 0.25 +. o *. 0.3
    let #(points, rng) =
      int.range(from: 0, to: n + 1, with: #([], rng), run: fn(acc, i) {
        let #(pts, rng) = acc
        let a = start +. int.to_float(i) /. int.to_float(n) *. { tau +. over }
        let #(w, rng) = signed(rng)
        let w = 1.0 +. w *. 0.03 *. k
        #([#(cx +. cos(a) *. rx *. w, cy +. sin(a) *. ry *. w), ..pts], rng)
      })
    let points = list.reverse(points)
    #(catmull_rom(points), rng)
  }
  let #(a, rng) = pass(rng)
  let #(b, rng) = pass(rng)
  #(a <> b, rng)
}

fn catmull_rom(points: List(#(Float, Float))) -> String {
  case points {
    [first, ..] -> {
      let arr = points
      let n = list.length(arr)
      let at = fn(i: Int) {
        let i = int.clamp(i, 0, n - 1)
        case list.drop(arr, i) {
          [p, ..] -> p
          [] -> first
        }
      }
      let segments =
        int.range(from: 1, to: n - 1, with: [], run: fn(acc, i) {
          let p0 = at(i - 1)
          let p1 = at(i)
          let p2 = at(i + 1)
          let p3 = at(i + 2)
          let seg =
            "C"
            <> f(p1.0 +. { p2.0 -. p0.0 } /. 6.0)
            <> " "
            <> f(p1.1 +. { p2.1 -. p0.1 } /. 6.0)
            <> " "
            <> f(p2.0 -. { p3.0 -. p1.0 } /. 6.0)
            <> " "
            <> f(p2.1 -. { p3.1 -. p1.1 } /. 6.0)
            <> " "
            <> f(p2.0)
            <> " "
            <> f(p2.1)
          [seg, ..acc]
        })
        |> list.reverse
      "M" <> f(first.0) <> " " <> f(first.1) <> string.concat(segments)
    }
    [] -> ""
  }
}

/// Hachure lines at about -41° covering a w×h box (clip them to a shape).
pub fn hachure(rng: Rng, w: Float, h: Float, gap: Float) -> #(String, Rng) {
  let count = float.truncate({ w +. h } /. gap) + 1
  int.range(from: 0, to: count, with: #("", rng), run: fn(acc, i) {
    let #(d, rng) = acc
    let x = int.to_float(i) *. gap -. h
    let #(l, rng) = line(rng, x, h +. 4.0, x +. h *. 0.87, -4.0, 0.4)
    #(d <> l, rng)
  })
}

// --- SVG output -------------------------------------------------------------------

/// `color` is a colour token: ink, red, goal, goal-bg, task, task-bg, dec,
/// dec-bg (CSS classes `k-<token>` set the stroke; no inline styles, for CSP).
fn path(d: String, color: String, width: Float, extra: String) -> String {
  "<path d=\""
  <> d
  <> "\" fill=\"none\" class=\"k-"
  <> color
  <> "\" stroke-width=\""
  <> f(width)
  <> "\" stroke-linecap=\"round\" stroke-linejoin=\"round\" vector-effect=\"non-scaling-stroke\""
  <> extra
  <> "/>"
}

fn clip_id(rng_seed: String) -> String {
  let Rng(n) = seed(rng_seed <> "#clip")
  "c" <> int.to_base36(n)
}

fn filled(seed_text: String, rng: Rng, outline: String, w: Float, h: Float, color: String) -> #(String, Rng) {
  let id = clip_id(seed_text)
  let #(lines, rng) = hachure(rng, w, h, 7.0)
  #(
    "<clipPath id=\""
      <> id
      <> "\"><path d=\""
      <> outline
      <> "\"/></clipPath>"
      <> path(lines, color, 1.1, " clip-path=\"url(#" <> id <> ")\" opacity=\"0.9\""),
    rng,
  )
}

pub type Shape {
  Rect
  Ellipse
}

/// A sketched frame stretched over its parent (see `.sk > svg.frame` CSS).
/// `w`/`h` set the aspect the jitter is designed for.
pub fn frame(
  seed_text: String,
  shape: Shape,
  w: Int,
  h: Int,
  stroke: String,
  fill: Option(String),
) -> String {
  let rng = seed(seed_text)
  let wf = int.to_float(w)
  let hf = int.to_float(h)
  let small = h < 40
  let #(body, _) = case shape {
    Ellipse -> {
      let cx = wf /. 2.0
      let cy = hf /. 2.0
      let rx = wf /. 2.0 -. 3.0
      let ry = hf /. 2.0 -. 3.0
      let outline =
        "M" <> f(cx -. rx) <> " " <> f(cy) <> "a" <> f(rx) <> " " <> f(ry)
        <> " 0 1 0 " <> f(rx *. 2.0) <> " 0a" <> f(rx) <> " " <> f(ry) <> " 0 1 0 "
        <> f(0.0 -. rx *. 2.0) <> " 0"
      let #(fill_svg, rng) = case fill {
        Some(color) -> filled(seed_text, rng, outline, wf, hf, color)
        None -> #("", rng)
      }
      let #(d, rng) = ellipse(rng, cx, cy, rx, ry, 1.0)
      #(fill_svg <> path(d, stroke, 1.8, ""), rng)
    }
    Rect -> {
      let x0 = 5.0
      let y0 = 5.0
      let x1 = wf -. 5.0
      let y1 = hf -. 5.0
      let outline =
        "M" <> f(x0) <> " " <> f(y0) <> "H" <> f(x1) <> "V" <> f(y1) <> "H" <> f(x0) <> "Z"
      let #(fill_svg, rng) = case fill {
        Some(color) -> filled(seed_text, rng, outline, wf, hf, color)
        None -> #("", rng)
      }
      let k = case small {
        True -> 0.6
        False -> 1.0
      }
      let #(d, rng) = polygon(rng, [#(x0, y0), #(x1, y0), #(x1, y1), #(x0, y1)], k)
      let width = case small {
        True -> 1.3
        False -> 1.7
      }
      #(fill_svg <> path(d, stroke, width, ""), rng)
    }
  }
  "<svg class=\"frame\" viewBox=\"0 0 "
  <> int.to_string(w)
  <> " "
  <> int.to_string(h)
  <> "\" preserveAspectRatio=\"none\" aria-hidden=\"true\">"
  <> body
  <> "</svg>"
}

pub type Icon {
  GoalIcon
  TaskIcon
  DecisionIcon(blocking: Bool)
}

/// A 22px category icon.
pub fn icon(kind: Icon, seed_text: String) -> String {
  let size = 22.0
  let m = 3.0
  let z = size -. m
  let rng = seed(seed_text)
  let #(body, _) = case kind {
    GoalIcon -> {
      let c = size /. 2.0
      let r = size /. 2.0 -. m
      let outline =
        "M" <> f(c -. r) <> " " <> f(c) <> "a" <> f(r) <> " " <> f(r) <> " 0 1 0 "
        <> f(r *. 2.0) <> " 0a" <> f(r) <> " " <> f(r) <> " 0 1 0 " <> f(0.0 -. r *. 2.0) <> " 0"
      let #(fill_svg, rng) = filled(seed_text, rng, outline, size, size, "goal-bg")
      let #(d, rng) = ellipse(rng, c, c, r, r, 0.8)
      #(fill_svg <> path(d, "goal", 1.8, ""), rng)
    }
    TaskIcon -> {
      let pts = [#(size /. 2.0, m), #(z, z), #(m, z)]
      let outline = "M" <> f(size /. 2.0) <> " " <> f(m) <> "L" <> f(z) <> " " <> f(z) <> "L" <> f(m) <> " " <> f(z) <> "Z"
      let #(fill_svg, rng) = filled(seed_text, rng, outline, size, size, "task-bg")
      let #(d, rng) = polygon(rng, pts, 0.6)
      #(fill_svg <> path(d, "task", 1.8, ""), rng)
    }
    DecisionIcon(blocking) -> {
      let c = size /. 2.0
      let pts = [#(c, m -. 1.0), #(z +. 1.0, c), #(c, z +. 1.0), #(m -. 1.0, c)]
      let solid = case blocking {
        True ->
          "<path d=\"M" <> f(c) <> " " <> f(m -. 1.0) <> "L" <> f(z +. 1.0) <> " " <> f(c)
          <> "L" <> f(c) <> " " <> f(z +. 1.0) <> "L" <> f(m -. 1.0) <> " " <> f(c)
          <> "Z\" class=\"f-dec\" opacity=\"0.85\"/>"
        False -> ""
      }
      let #(d, rng) = polygon(rng, pts, 0.6)
      #(solid <> path(d, "dec", 1.9, ""), rng)
    }
  }
  "<svg class=\"icon\" width=\"22\" height=\"22\" viewBox=\"0 0 22 22\" aria-hidden=\"true\">"
  <> body
  <> "</svg>"
}
