//// OAuth Client ID Metadata Documents: when a `client_id` is an https URL,
//// fetch the JSON document it points to (with SSRF guards) and cache it.

import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import huddy/model.{type OAuthClient, OAuthClient}
import huddy/net
import huddy/sys

pub type Fetch =
  fn(String) -> Result(#(Int, List(#(String, String)), String), String)

const max_bytes = 10_240

/// Validate that a URL is an acceptable CIMD client_id and that its host
/// resolves only to public addresses.
pub fn check_url(url: String, trusted_hosts: List(String)) -> Result(String, String) {
  use parsed <- result.try(uri.parse(url) |> result.replace_error("client_id is not a URL"))
  use host <- result.try(case parsed.scheme, parsed.host {
    Some("https"), Some(host) -> Ok(string.lowercase(host))
    _, _ -> Error("client_id must be an https URL")
  })
  use _ <- result.try(case parsed.path {
    "" | "/" -> Error("client_id URL must have a path")
    _ -> Ok(Nil)
  })
  use _ <- result.try(case parsed.fragment, parsed.userinfo {
    None, None -> Ok(Nil)
    _, _ -> Error("client_id URL must not have a fragment or credentials")
  })
  use _ <- result.try(case trusted_hosts {
    [] -> Ok(Nil)
    hosts ->
      case list.contains(hosts, host) {
        True -> Ok(Nil)
        False -> Error("client host " <> host <> " is not trusted by this server")
      }
  })
  use addresses <- result.try(
    sys.getaddrs(host) |> result.replace_error("cannot resolve " <> host),
  )
  case list.all(addresses, net.is_public) {
    True -> Ok(host)
    False -> Error(host <> " resolves to a non-public address")
  }
}

/// The real fetcher: no redirects, 5 s timeout.
pub fn http_fetch(url: String) -> Result(#(Int, List(#(String, String)), String), String) {
  use req <- result.try(request.to(url) |> result.replace_error("bad URL"))
  let req = request.set_header(req, "accept", "application/json")
  httpc.configure()
  |> httpc.timeout(5000)
  |> httpc.follow_redirects(False)
  |> httpc.dispatch(req)
  |> result.map(fn(resp) { #(resp.status, resp.headers, resp.body) })
  |> result.replace_error("cannot fetch client metadata")
}

/// Fetch and validate a client's metadata document.
pub fn fetch(
  url: String,
  trusted_hosts: List(String),
  get: Fetch,
  now: Int,
) -> Result(OAuthClient, String) {
  use host <- result.try(check_url(url, trusted_hosts))
  use #(status, headers, body) <- result.try(get(url))
  use _ <- result.try(case status {
    200 -> Ok(Nil)
    s -> Error("client metadata returned HTTP " <> int.to_string(s))
  })
  use _ <- result.try(case string.byte_size(body) > max_bytes {
    True -> Error("client metadata document is too large")
    False -> Ok(Nil)
  })
  let decoder = {
    use client_id <- decode.field("client_id", decode.string)
    use client_name <- decode.optional_field("client_name", host, decode.string)
    use redirect_uris <- decode.field("redirect_uris", decode.list(decode.string))
    decode.success(#(client_id, client_name, redirect_uris))
  }
  use #(client_id, client_name, redirect_uris) <- result.try(
    json.parse(body, decoder)
    |> result.replace_error("client metadata is not a valid document"),
  )
  use _ <- result.try(case client_id == url {
    True -> Ok(Nil)
    False -> Error("client metadata client_id does not match its URL")
  })
  use _ <- result.try(case redirect_uris {
    [] -> Error("client metadata has no redirect_uris")
    _ -> Ok(Nil)
  })
  let max_age =
    list.key_find(headers, "cache-control")
    |> result.try(parse_max_age)
    |> result.unwrap(3600)
    |> int.clamp(300, 86_400)
  Ok(OAuthClient(
    client_id:,
    kind: model.Cimd,
    client_name: string.slice(client_name, 0, 80),
    redirect_uris:,
    metadata: body,
    fetched_at: Some(now),
    cache_until: Some(now + max_age * 1000),
    created_at: now,
  ))
}

fn parse_max_age(cache_control: String) -> Result(Int, Nil) {
  cache_control
  |> string.split(",")
  |> list.find_map(fn(part) {
    case string.split_once(string.trim(part), "=") {
      Ok(#("max-age", n)) -> int.parse(n)
      _ -> Error(Nil)
    }
  })
}
