//// A minimal S3 client: get, put, delete and list objects, signed with AWS
//// Signature Version 4. Works with AWS S3 and S3-compatible stores (MinIO,
//// Cloudflare R2, …) through a custom endpoint and path-style addressing.

import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import huddy/sys

pub type Config {
  Config(
    region: String,
    scheme: http.Scheme,
    /// endpoint host, e.g. "s3.eu-west-1.amazonaws.com" or "minio.internal"
    host: String,
    /// None for the scheme's default port
    port: Option(Int),
    /// True: https://host/bucket/key; False: https://bucket.host/key
    path_style: Bool,
    access_key_id: String,
    secret_access_key: String,
    /// "" when not using temporary credentials
    session_token: String,
  )
}

/// Long enough for document zips (up to `limits.document_max_mb`) on a slow
/// link; the same for every request, the state file included.
const timeout_ms = 600_000

/// Fetch an object. A missing object is `Error("enoent")`, as for files; a
/// missing bucket is an ordinary error.
pub fn get(
  config: Config,
  bucket: String,
  key: String,
) -> Result(BitArray, String) {
  use resp <- result.try(send(config, http.Get, bucket, key, [], <<>>, []))
  case resp.status {
    200 -> Ok(resp.body)
    404 ->
      case error_code(resp) {
        "NoSuchBucket" -> Error(failure("GET", bucket, key, resp))
        _ -> Error("enoent")
      }
    _ -> Error(failure("GET", bucket, key, resp))
  }
}

/// Store an object. S3 replaces objects atomically: readers see the old
/// object or the new one, never a mix.
pub fn put(
  config: Config,
  bucket: String,
  key: String,
  body: BitArray,
  content_type: String,
) -> Result(Nil, String) {
  use resp <- result.try(
    send(config, http.Put, bucket, key, [], body, [
      #("content-type", content_type),
    ]),
  )
  case resp.status {
    200 -> Ok(Nil)
    _ -> Error(failure("PUT", bucket, key, resp))
  }
}

/// Delete an object; deleting a missing object succeeds.
pub fn delete(
  config: Config,
  bucket: String,
  key: String,
) -> Result(Nil, String) {
  use resp <- result.try(send(config, http.Delete, bucket, key, [], <<>>, []))
  case resp.status {
    200 | 204 | 404 -> Ok(Nil)
    _ -> Error(failure("DELETE", bucket, key, resp))
  }
}

/// All keys in the bucket that start with `prefix`.
pub fn list(
  config: Config,
  bucket: String,
  prefix: String,
) -> Result(List(String), String) {
  list_from(config, bucket, prefix, None, [])
}

fn list_from(
  config: Config,
  bucket: String,
  prefix: String,
  token: Option(String),
  acc: List(List(String)),
) -> Result(List(String), String) {
  let query = case token {
    Some(t) -> [#("continuation-token", t)]
    None -> []
  }
  let query = [#("list-type", "2"), #("prefix", prefix), ..query]
  use resp <- result.try(send(config, http.Get, bucket, "", query, <<>>, []))
  use body <- result.try(case resp.status, bit_array.to_string(resp.body) {
    200, Ok(body) -> Ok(body)
    _, _ -> Error(failure("LIST", bucket, prefix, resp))
  })
  let acc = [xml_values(body, "Key"), ..acc]
  case
    xml_values(body, "IsTruncated"),
    xml_values(body, "NextContinuationToken")
  {
    ["true"], [next] -> list_from(config, bucket, prefix, Some(next), acc)
    _, _ -> Ok(acc |> list.reverse |> list.flatten)
  }
}

// --- requests ------------------------------------------------------------------

fn send(
  config: Config,
  method: http.Method,
  bucket: String,
  key: String,
  query: List(#(String, String)),
  body: BitArray,
  unsigned_headers: List(#(String, String)),
) -> Result(Response(BitArray), String) {
  let req =
    build(config, method, bucket, key, query, body, sys.now_ms())
    |> list.fold(unsigned_headers, _, fn(req, h) {
      request.set_header(req, h.0, h.1)
    })
  httpc.configure()
  |> httpc.timeout(timeout_ms)
  |> httpc.follow_redirects(False)
  |> httpc.dispatch_bits(req)
  |> result.map_error(fn(e) {
    let target = "s3://" <> bucket <> "/" <> key
    case e {
      httpc.ResponseTimeout -> "S3 timed out (" <> target <> ")"
      httpc.FailedToConnect(..) ->
        "cannot connect to S3 at " <> config.host <> " (" <> target <> ")"
      httpc.InvalidUtf8Response -> "invalid response from S3 (" <> target <> ")"
    }
  })
}

/// A signed request. Public for tests. Headers added afterwards (such as
/// `content-type`) are not signed.
pub fn build(
  config: Config,
  method: http.Method,
  bucket: String,
  key: String,
  query: List(#(String, String)),
  body: BitArray,
  now: Int,
) -> Request(BitArray) {
  let #(host, path) = case config.path_style, key {
    True, "" -> #(config.host, "/" <> bucket)
    True, _ -> #(config.host, "/" <> bucket <> "/" <> key)
    False, _ -> #(bucket <> "." <> config.host, "/" <> key)
  }
  let path = encode(path, False)
  let query =
    query
    |> list.map(fn(pair) { encode(pair.0, True) <> "=" <> encode(pair.1, True) })
    |> list.sort(string.compare)
    |> string.join("&")
  let host_header = case config.port {
    Some(port) -> host <> ":" <> int.to_string(port)
    None -> host
  }
  let amz_date = sys.amz_date(now)
  let payload_hash = hex(crypto.hash(crypto.Sha256, body))
  let headers = [
    #("host", host_header),
    #("x-amz-content-sha256", payload_hash),
    #("x-amz-date", amz_date),
    ..case config.session_token {
      "" -> []
      token -> [#("x-amz-security-token", token)]
    }
  ]
  let auth =
    authorization(
      config,
      http.method_to_string(method) |> string.uppercase,
      path,
      query,
      headers,
      payload_hash,
      amz_date,
    )
  let headers =
    headers
    |> list.filter(fn(h) { h.0 != "host" })
    |> list.prepend(#("authorization", auth))
  Request(
    method:,
    headers:,
    body:,
    scheme: config.scheme,
    host:,
    port: config.port,
    path:,
    query: case query {
      "" -> None
      q -> Some(q)
    },
  )
}

/// The SigV4 `Authorization` header. `path` and `query` are already
/// canonical (encoded, query sorted); `headers` are the signed headers, with
/// lowercase names.
pub fn authorization(
  config: Config,
  method: String,
  path: String,
  query: String,
  headers: List(#(String, String)),
  payload_hash: String,
  amz_date: String,
) -> String {
  let headers =
    headers
    |> list.map(fn(h) { #(string.lowercase(h.0), string.trim(h.1)) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let signed_headers = headers |> list.map(fn(h) { h.0 }) |> string.join(";")
  let canonical_request =
    [
      method,
      path,
      query,
      headers |> list.map(fn(h) { h.0 <> ":" <> h.1 <> "\n" }) |> string.concat,
      signed_headers,
      payload_hash,
    ]
    |> string.join("\n")
  let date = string.slice(amz_date, 0, 8)
  let scope = date <> "/" <> config.region <> "/s3/aws4_request"
  let string_to_sign =
    [
      "AWS4-HMAC-SHA256",
      amz_date,
      scope,
      hex(crypto.hash(crypto.Sha256, bit_array.from_string(canonical_request))),
    ]
    |> string.join("\n")
  let signing_key =
    [date, config.region, "s3", "aws4_request"]
    |> list.fold(
      bit_array.from_string("AWS4" <> config.secret_access_key),
      hmac,
    )
  let signature = hex(hmac(signing_key, string_to_sign))
  "AWS4-HMAC-SHA256 Credential="
  <> config.access_key_id
  <> "/"
  <> scope
  <> ", SignedHeaders="
  <> signed_headers
  <> ", Signature="
  <> signature
}

fn hmac(key: BitArray, data: String) -> BitArray {
  crypto.hmac(bit_array.from_string(data), crypto.Sha256, key)
}

fn hex(bits: BitArray) -> String {
  bit_array.base16_encode(bits) |> string.lowercase
}

/// SigV4 URI encoding: everything but unreserved characters becomes %XX;
/// "/" is kept in paths and encoded in query components.
fn encode(text: String, slash: Bool) -> String {
  encode_bytes(bit_array.from_string(text), slash, [])
}

fn encode_bytes(bits: BitArray, slash: Bool, acc: List(String)) -> String {
  case bits {
    <<byte, rest:bytes>> -> {
      let keep =
        { byte >= 0x41 && byte <= 0x5A }
        || { byte >= 0x61 && byte <= 0x7A }
        || { byte >= 0x30 && byte <= 0x39 }
        || byte == 0x2D
        || byte == 0x2E
        || byte == 0x5F
        || byte == 0x7E
        || { byte == 0x2F && !slash }
      let piece = case keep {
        True -> {
          let assert Ok(c) = bit_array.to_string(<<byte>>)
          c
        }
        False -> "%" <> string.pad_start(int.to_base16(byte), 2, "0")
      }
      encode_bytes(rest, slash, [piece, ..acc])
    }
    _ -> acc |> list.reverse |> string.concat
  }
}

// --- responses -----------------------------------------------------------------

fn error_code(resp: Response(BitArray)) -> String {
  let body = bit_array.to_string(resp.body) |> result.unwrap("")
  xml_values(body, "Code") |> list.first |> result.unwrap("")
}

fn failure(
  op: String,
  bucket: String,
  key: String,
  resp: Response(BitArray),
) -> String {
  let body = bit_array.to_string(resp.body) |> result.unwrap("")
  let detail = case error_code(resp), xml_values(body, "Message") {
    "", _ -> ""
    code, [message, ..] -> ": " <> code <> " (" <> message <> ")"
    code, _ -> ": " <> code
  }
  "S3 "
  <> op
  <> " s3://"
  <> bucket
  <> "/"
  <> key
  <> " failed with HTTP "
  <> int.to_string(resp.status)
  <> detail
}

/// The text of every `<tag>…</tag>` element, unescaped. S3's XML responses
/// are flat enough that this is all the parsing they need.
pub fn xml_values(xml: String, tag: String) -> List(String) {
  case string.split(xml, "<" <> tag <> ">") {
    [_, ..parts] ->
      list.filter_map(parts, fn(part) {
        string.split_once(part, "</" <> tag <> ">")
        |> result.map(fn(pair) { unescape(pair.0) })
      })
    [] -> []
  }
}

fn unescape(text: String) -> String {
  text
  |> string.replace("&lt;", "<")
  |> string.replace("&gt;", ">")
  |> string.replace("&quot;", "\"")
  |> string.replace("&apos;", "'")
  |> string.replace("&amp;", "&")
}
