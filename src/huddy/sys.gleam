//// Thin bindings over `huddy_ffi.erl`, plus small helpers for tokens and hashes.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/int
import gleam/string

@external(erlang, "huddy_ffi", "now_ms")
pub fn now_ms() -> Int

@external(erlang, "huddy_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "huddy_ffi", "atomic_write")
pub fn atomic_write(path: String, data: BitArray) -> Result(Nil, String)

@external(erlang, "huddy_ffi", "read_file")
pub fn read_file(path: String) -> Result(BitArray, String)

@external(erlang, "huddy_ffi", "delete_file")
pub fn delete_file(path: String) -> Result(Nil, String)

@external(erlang, "huddy_ffi", "file_exists")
pub fn file_exists(path: String) -> Bool

@external(erlang, "huddy_ffi", "file_size")
pub fn file_size(path: String) -> Int

@external(erlang, "huddy_ffi", "ensure_dir")
pub fn ensure_dir(dir: String) -> Result(Nil, String)

@external(erlang, "huddy_ffi", "list_dir")
pub fn list_dir(dir: String) -> Result(List(String), String)

@external(erlang, "huddy_ffi", "utc_date_compact")
pub fn utc_date_compact(ms: Int) -> String

@external(erlang, "huddy_ffi", "getaddrs")
pub fn getaddrs(host: String) -> Result(List(List(Int)), Nil)

@external(erlang, "huddy_ffi", "send_email")
pub fn send_email(
  opts: Dict(SmtpKey, SmtpValue),
  from: String,
  to: String,
  subject: String,
  body: String,
) -> Result(Nil, String)

/// Keys and values for the SMTP options map handed to Erlang.
pub type SmtpKey {
  Host
  Port
  Username
  Password
  Tls
}

pub type SmtpValue

@external(erlang, "gleam_erlang_ffi", "identity")
pub fn smtp_value(value: a) -> SmtpValue

@external(erlang, "huddy_ffi", "limiter_init")
pub fn limiter_init() -> Nil

@external(erlang, "huddy_ffi", "rate_take")
fn rate_take(key: String, capacity: Int, refill_per_ms: Float, now: Int) -> Bool

/// Route outbound HTTPS through $HTTPS_PROXY when set; returns host:port.
@external(erlang, "huddy_ffi", "configure_proxy")
pub fn configure_proxy() -> Result(String, Nil)

@external(erlang, "huddy_ffi", "halt")
pub fn halt(code: Int) -> Nil

@external(erlang, "huddy_ffi", "rescue")
pub fn rescue(f: fn() -> a) -> Result(a, String)

/// Take one token from the bucket `key`, which holds `capacity` tokens and
/// refills completely every `period_ms`. Returns False when rate limited.
pub fn rate_limit(key: String, capacity: Int, period_ms: Int) -> Bool {
  let refill = int.to_float(capacity) /. int.to_float(int.max(period_ms, 1))
  rate_take(key, capacity, refill, now_ms())
}

/// A URL-safe random token with `bytes` bytes of entropy.
pub fn random_token(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes)
  |> bit_array.base64_url_encode(False)
}

/// Lowercase hex SHA-256 of a string.
pub fn sha256_hex(value: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(value))
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Lowercase hex HMAC-SHA256.
pub fn hmac_hex(value: String, key: String) -> String {
  crypto.hmac(
    bit_array.from_string(value),
    crypto.Sha256,
    bit_array.from_string(key),
  )
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Constant-time string comparison.
pub fn secure_equal(a: String, b: String) -> Bool {
  crypto.secure_compare(bit_array.from_string(a), bit_array.from_string(b))
}

/// A uniformly random 6-digit code, zero padded.
pub fn random_code() -> String {
  let assert <<n:unsigned-size(32)>> = crypto.strong_random_bytes(4)
  n % 1_000_000
  |> int.to_string
  |> string.pad_start(6, "0")
}
