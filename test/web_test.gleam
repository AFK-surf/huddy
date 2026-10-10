import gleam/list
import gleam/option.{None, Some}
import gleam/string
import huddy/net
import huddy/oauth/server as oauth
import huddy/similar
import huddy/web/html
import huddy/web/sketch

pub fn sketch_is_deterministic_test() {
  let a = sketch.frame("i41:3", sketch.Rect, 280, 200, "dec", Some("dec-bg"))
  let b = sketch.frame("i41:3", sketch.Rect, 280, 200, "dec", Some("dec-bg"))
  let c = sketch.frame("i41:4", sketch.Rect, 280, 200, "dec", Some("dec-bg"))
  assert a == b
  assert a != c
  assert string.contains(a, "viewBox=\"0 0 280 200\"")
  assert string.contains(a, "clipPath")
  assert !string.contains(a, "style=")
}

pub fn icons_render_test() {
  let goal = sketch.icon(sketch.GoalIcon, "x")
  let blocking = sketch.icon(sketch.DecisionIcon(True), "x")
  let open = sketch.icon(sketch.DecisionIcon(False), "x")
  assert string.contains(goal, "k-goal")
  assert string.contains(blocking, "f-dec")
  assert !string.contains(open, "f-dec")
  let e = sketch.frame("g", sketch.Ellipse, 320, 90, "goal", None)
  assert string.contains(e, "C")
}

pub fn html_escapes_text_and_attributes_test() {
  let node = html.el("a", [#("title", "\"><script>")], [html.text("<b>&'")])
  assert html.to_string(node)
    == "<a title=\"&quot;&gt;&lt;script&gt;\">&lt;b&gt;&amp;&#39;</a>"
  assert html.to_string(html.el("input", [#("name", "x")], []))
    == "<input name=\"x\">"
}

pub fn ip_parsing_test() {
  assert net.parse_ip("10.1.2.3") == Ok([10, 1, 2, 3])
  assert net.parse_ip("::1") == Ok([0, 0, 0, 0, 0, 0, 0, 1])
  assert net.parse_ip("2001:db8::8a2e:370:7334")
    == Ok([0x2001, 0xdb8, 0, 0, 0, 0x8a2e, 0x370, 0x7334])
  assert net.parse_ip("256.1.1.1") == Error(Nil)
  assert net.parse_ip("1::2::3") == Error(Nil)
}

pub fn public_address_classification_test() {
  let public = fn(s) {
    let assert Ok(ip) = net.parse_ip(s)
    net.is_public(ip)
  }
  assert public("93.184.216.34")
  assert public("2606:4700::1111")
  assert !public("127.0.0.1")
  assert !public("10.0.0.5")
  assert !public("172.20.1.1")
  assert !public("192.168.1.1")
  assert !public("169.254.169.254")
  assert !public("100.64.0.1")
  assert !public("::1")
  assert !public("fd00::1")
  assert !public("fe80::1")
  assert !public("::ffff:10.0.0.1")
}

pub fn cidr_test() {
  let assert Ok(cidr) = net.parse_cidr("10.0.0.0/8")
  let assert Ok(inside) = net.parse_ip("10.200.3.4")
  let assert Ok(outside) = net.parse_ip("11.0.0.1")
  assert net.cidr_contains(cidr, inside)
  assert !net.cidr_contains(cidr, outside)
}

pub fn pkce_test() {
  // RFC 7636 appendix B
  let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  assert oauth.pkce_ok(verifier, challenge)
  assert !oauth.pkce_ok(verifier <> "x", challenge)
  assert !oauth.pkce_ok("short", challenge)
}

pub fn loopback_redirects_may_change_port_test() {
  assert oauth.redirect_matches(
    "http://127.0.0.1/callback",
    "http://127.0.0.1:53682/callback",
  )
  assert oauth.redirect_matches(
    "https://app.example/cb",
    "https://app.example/cb",
  )
  assert !oauth.redirect_matches(
    "https://app.example/cb",
    "https://app.example:444/cb",
  )
  assert !oauth.redirect_matches(
    "http://127.0.0.1/callback",
    "http://127.0.0.1:1/other",
  )
  assert !oauth.redirect_matches(
    "http://127.0.0.1/callback",
    "http://evil.example/callback",
  )
}

pub fn scope_normalization_test() {
  assert oauth.normalize_scope("") == Ok("huddy:read huddy:write")
  assert oauth.normalize_scope("huddy:write") == Ok("huddy:read huddy:write")
  assert oauth.normalize_scope("huddy:read openid") == Ok("huddy:read")
  assert oauth.normalize_scope("admin") == Error(Nil)
}

pub fn similarity_prefers_close_text_test() {
  let items = [
    "Deflake auth test suite",
    "Write the release notes",
    "Fix flaky auth tests",
  ]
  let top =
    similar.top(
      "Deflake OAuth refresh test",
      items,
      fn(x) { x },
      fn(_) { 0.0 },
      0.05,
      2,
    )
  assert list.first(top) == Ok("Deflake auth test suite")
  assert !list.contains(top, "Write the release notes")
}
