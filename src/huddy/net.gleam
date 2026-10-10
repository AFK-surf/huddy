//// IP address parsing, CIDR matching, and public/private classification
//// (used for trusted proxies and for SSRF guards on outbound fetches).

import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// An IP address as a list of integers: 4 octets (IPv4) or 8 hextets (IPv6).
pub type Ip =
  List(Int)

pub type Cidr {
  Cidr(address: Ip, prefix: Int)
}

pub fn parse_ip(text: String) -> Result(Ip, Nil) {
  let text = string.trim(text)
  case string.contains(text, ":") {
    True -> parse_ipv6(text)
    False -> parse_ipv4(text)
  }
}

fn parse_ipv4(text: String) -> Result(Ip, Nil) {
  let parts = string.split(text, ".")
  use octets <- result.try(list.try_map(parts, int.parse))
  case list.length(octets) == 4 && list.all(octets, fn(o) { o >= 0 && o < 256 })
  {
    True -> Ok(octets)
    False -> Error(Nil)
  }
}

fn parse_ipv6(text: String) -> Result(Ip, Nil) {
  let text = case string.starts_with(text, "[") && string.ends_with(text, "]") {
    True -> text |> string.drop_start(1) |> string.drop_end(1)
    False -> text
  }
  let parse_groups = fn(s: String) -> Result(List(Int), Nil) {
    case s {
      "" -> Ok([])
      _ ->
        string.split(s, ":")
        |> list.try_map(fn(g) {
          case string.contains(g, ".") {
            // embedded IPv4, e.g. ::ffff:10.0.0.1
            True ->
              parse_ipv4(g)
              |> result.map(fn(o) {
                case o {
                  [a, b, c, d] -> [a * 256 + b, c * 256 + d]
                  _ -> []
                }
              })
            False ->
              int.base_parse(g, 16)
              |> result.try(fn(n) {
                case n >= 0 && n < 65_536 && string.length(g) <= 4 {
                  True -> Ok([n])
                  False -> Error(Nil)
                }
              })
          }
        })
        |> result.map(list.flatten)
    }
  }
  case string.split_once(text, "::") {
    Ok(#(left, right)) -> {
      use l <- result.try(parse_groups(left))
      use r <- result.try(parse_groups(right))
      let missing = 8 - list.length(l) - list.length(r)
      case missing >= 1 {
        True -> Ok(list.flatten([l, list.repeat(0, missing), r]))
        False -> Error(Nil)
      }
    }
    Error(_) -> {
      use groups <- result.try(parse_groups(text))
      case list.length(groups) == 8 {
        True -> Ok(groups)
        False -> Error(Nil)
      }
    }
  }
}

pub fn parse_cidr(text: String) -> Result(Cidr, Nil) {
  case string.split_once(text, "/") {
    Ok(#(addr, bits)) -> {
      use ip <- result.try(parse_ip(addr))
      use prefix <- result.try(int.parse(bits))
      case prefix >= 0 && prefix <= width(ip) {
        True -> Ok(Cidr(ip, prefix))
        False -> Error(Nil)
      }
    }
    Error(_) -> parse_ip(text) |> result.map(fn(ip) { Cidr(ip, width(ip)) })
  }
}

fn width(ip: Ip) -> Int {
  case list.length(ip) {
    4 -> 32
    _ -> 128
  }
}

fn to_bits(ip: Ip) -> List(Bool) {
  let size = case list.length(ip) {
    4 -> 8
    _ -> 16
  }
  list.flat_map(ip, fn(part) {
    int.range(from: 0, to: size, with: [], run: list.prepend)
    |> list.map(fn(bit) { int.bitwise_and(int.bitwise_shift_right(part, bit), 1) == 1 })
  })
}

pub fn cidr_contains(cidr: Cidr, ip: Ip) -> Bool {
  list.length(cidr.address) == list.length(ip)
  && list.take(to_bits(cidr.address), cidr.prefix)
  == list.take(to_bits(ip), cidr.prefix)
}

/// Unwrap IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) to plain IPv4.
pub fn normalize(ip: Ip) -> Ip {
  case ip {
    [0, 0, 0, 0, 0, 65_535, hi, lo] -> [
      hi / 256,
      hi % 256,
      lo / 256,
      lo % 256,
    ]
    _ -> ip
  }
}

const non_public = [
  "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
  "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16",
  "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4",
  "240.0.0.0/4", "::/128", "::1/128", "64:ff9b::/96", "100::/64", "2001:db8::/32",
  "fc00::/7", "fe80::/10", "ff00::/8",
]

/// True for globally routable unicast addresses; False for loopback, private,
/// link-local, unique-local, multicast, documentation and reserved ranges.
pub fn is_public(ip: Ip) -> Bool {
  let ip = normalize(ip)
  !list.any(non_public, fn(text) {
    case parse_cidr(text) {
      Ok(cidr) -> cidr_contains(cidr, ip)
      Error(_) -> False
    }
  })
}

pub fn to_string(ip: Ip) -> String {
  case ip {
    [_, _, _, _] -> ip |> list.map(int.to_string) |> string.join(".")
    _ ->
      ip
      |> list.map(fn(n) { int.to_base16(n) |> string.lowercase })
      |> string.join(":")
  }
}
