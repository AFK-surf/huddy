import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string
import huddy/blob
import huddy/config
import huddy/model
import huddy/persist
import huddy/s3
import huddy/state
import mist
import support

fn aws_docs_config() -> s3.Config {
  s3.Config(
    region: "us-east-1",
    scheme: http.Https,
    host: "s3.amazonaws.com",
    port: None,
    path_style: False,
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: "",
  )
}

const empty_sha256 =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

// The worked examples in the S3 docs ("Signature Calculations for the
// Authorization Header: Transferring Payload in a Single Chunk").

pub fn aws_docs_get_object_test() {
  let auth =
    s3.authorization(
      aws_docs_config(),
      "GET",
      "/test.txt",
      "",
      [
        #("Host", "examplebucket.s3.amazonaws.com"),
        #("Range", "bytes=0-9"),
        #("x-amz-content-sha256", empty_sha256),
        #("x-amz-date", "20130524T000000Z"),
      ],
      empty_sha256,
      "20130524T000000Z",
    )
  assert auth
    == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
}

pub fn aws_docs_list_objects_test() {
  let auth =
    s3.authorization(
      aws_docs_config(),
      "GET",
      "/",
      "max-keys=2&prefix=J",
      [
        #("host", "examplebucket.s3.amazonaws.com"),
        #("x-amz-content-sha256", empty_sha256),
        #("x-amz-date", "20130524T000000Z"),
      ],
      empty_sha256,
      "20130524T000000Z",
    )
  assert string.ends_with(
    auth,
    "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7",
  )
}

// Signatures below were computed with botocore (S3SigV4Auth) for the same
// requests, at 2026-10-11T13:14:15Z.

const botocore_time = 1_791_724_455_000

fn example_config() -> s3.Config {
  s3.Config(
    region: "eu-west-1",
    scheme: http.Https,
    host: "s3.eu-west-1.amazonaws.com",
    port: None,
    path_style: False,
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    session_token: "",
  )
}

fn header(req: Request(a), name: String) -> String {
  request.get_header(req, name) |> result.unwrap("")
}

pub fn put_path_style_with_session_token_test() {
  let config =
    s3.Config(
      ..example_config(),
      scheme: http.Http,
      host: "localhost",
      port: Some(9000),
      path_style: True,
      session_token: "TOKEN/abc+=",
    )
  let req =
    s3.build(
      config,
      http.Put,
      "huddy-state",
      "team a/hüddy.json",
      [],
      bit_array.from_string("{\"format\":1}"),
      botocore_time,
    )
  assert req.host == "localhost"
  assert req.port == Some(9000)
  assert req.path == "/huddy-state/team%20a/h%C3%BCddy.json"
  assert header(req, "x-amz-date") == "20261011T131415Z"
  assert header(req, "x-amz-security-token") == "TOKEN/abc+="
  assert header(req, "authorization")
    == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261011/eu-west-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=c81eb0c5f664dc653b2c7bfbd918c01d7f5aac19b28048d0a4bf83c6cb4d286f"
}

pub fn list_virtual_hosted_test() {
  let req =
    s3.build(
      example_config(),
      http.Get,
      "acme-huddy",
      "",
      [
        #("list-type", "2"),
        #("prefix", "prod/backups/"),
        #("continuation-token", "1/ab=="),
      ],
      <<>>,
      botocore_time,
    )
  assert req.host == "acme-huddy.s3.eu-west-1.amazonaws.com"
  assert req.path == "/"
  assert req.query
    == Some(
      "continuation-token=1%2Fab%3D%3D&list-type=2&prefix=prod%2Fbackups%2F",
    )
  assert header(req, "authorization")
    == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261011/eu-west-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=440750588a15b966e5e0b6b60cf8562625a856fcb5a243a3b79a068b3fd05659"
}

pub fn xml_values_test() {
  let xml =
    "<ListBucketResult><IsTruncated>false</IsTruncated>"
    <> "<Contents><Key>a/huddy-1.json</Key></Contents>"
    <> "<Contents><Key>a/b&amp;c.json</Key></Contents></ListBucketResult>"
  assert s3.xml_values(xml, "Key") == ["a/huddy-1.json", "a/b&c.json"]
  assert s3.xml_values(xml, "IsTruncated") == ["false"]
  assert s3.xml_values(xml, "Missing") == []
}

pub fn locations_test() {
  let s3 = example_config()
  let assert Ok(blob.Object(bucket: "b", key: "team/huddy.json", ..) as path) =
    blob.parse("s3://b/team/huddy.json", s3)
  assert blob.child(blob.parent(path), "backups")
    == blob.Object(s3, "b", "team/backups")
  let assert Ok(root) = blob.parse("s3://b/huddy.json", s3)
  assert blob.child(blob.parent(root), "backups")
    == blob.Object(s3, "b", "backups")
  assert blob.parse("s3://b/dir/", s3) == Ok(blob.Object(s3, "b", "dir"))
  assert blob.parse("s3://", s3) == Error(Nil)
  assert blob.parse("/var/lib/huddy/huddy.json", s3)
    == Ok(blob.File("/var/lib/huddy/huddy.json"))
}

// --- configuration ---------------------------------------------------------------

fn parse_with_storage(storage: String) -> Result(config.Config, String) {
  config.parse(bit_array.from_string("{
  \"team\": { \"name\": \"T\", \"base_url\": \"https://huddy.acme.dev\" },
  \"storage\": " <> storage <> ",
  \"secret_key\": \"0123456789abcdef0123456789abcdef\",
  \"auth\": { \"allowed_domains\": [\"acme.dev\"] },
  \"email\": { \"from\": \"h@acme.dev\", \"transport\": \"log\" },
  \"decision_model\": { \"enabled\": false }
}"))
}

pub fn s3_storage_config_test() {
  let assert Ok(c) =
    parse_with_storage(
      "{ \"path\": \"s3://acme-huddy/prod/huddy.json\",
         \"s3\": { \"region\": \"eu-central-1\", \"access_key_id\": \"AK\",
                   \"secret_access_key\": \"SK\" } }",
    )
  let assert blob.Object(s3:, bucket: "acme-huddy", key: "prod/huddy.json") =
    c.storage.path
  assert s3.host == "s3.eu-central-1.amazonaws.com"
  assert s3.scheme == http.Https
  assert !s3.path_style
  assert c.storage.backup_dir == blob.Object(s3, "acme-huddy", "prod/backups")
  assert c.storage.documents_dir
    == blob.Object(s3, "acme-huddy", "prod/documents")
}

pub fn s3_custom_endpoint_config_test() {
  let assert Ok(c) =
    parse_with_storage(
      "{ \"path\": \"s3://huddy/huddy.json\",
         \"backup_dir\": \"/var/lib/huddy/backups\",
         \"s3\": { \"endpoint\": \"http://minio.local:9000/\",
                   \"access_key_id\": \"AK\", \"secret_access_key\": \"SK\" } }",
    )
  let assert blob.Object(s3:, ..) = c.storage.path
  assert s3.scheme == http.Http
  assert s3.host == "minio.local"
  assert s3.port == Some(9000)
  assert s3.path_style
  assert c.storage.backup_dir == blob.File("/var/lib/huddy/backups")
}

pub fn s3_credentials_from_environment_test() {
  support.putenv("AWS_ACCESS_KEY_ID", "AK-ENV")
  support.putenv("AWS_SECRET_ACCESS_KEY", "SK-ENV")
  let assert Ok(c) =
    parse_with_storage("{ \"path\": \"s3://acme-huddy/huddy.json\" }")
  let assert blob.Object(s3:, ..) = c.storage.path
  assert s3.access_key_id == "AK-ENV"
  assert s3.secret_access_key == "SK-ENV"
}

pub fn s3_storage_config_errors_test() {
  let assert Error(message) =
    parse_with_storage(
      "{ \"path\": \"s3://acme-huddy/huddy.json\",
         \"s3\": { \"access_key_id\": \"\", \"secret_access_key\": \"\" } }",
    )
  assert string.contains(message, "needs credentials")
  let assert Error(message) =
    parse_with_storage(
      "{ \"path\": \"s3://acme-huddy\",
         \"s3\": { \"access_key_id\": \"AK\", \"secret_access_key\": \"SK\" } }",
    )
  assert string.contains(message, "must name an object")
  let assert Error(message) =
    parse_with_storage(
      "{ \"path\": \"s3://acme-huddy/huddy.json\",
         \"s3\": { \"endpoint\": \"ftp://x\", \"access_key_id\": \"AK\",
                   \"secret_access_key\": \"SK\" } }",
    )
  assert string.contains(message, "storage.s3")
}

// --- against a fake S3 server ----------------------------------------------------

type Objects =
  Subject(ObjectsMsg)

type ObjectsMsg {
  Get(key: String, reply: Subject(Result(BitArray, Nil)))
  Put(key: String, body: BitArray)
  Delete(key: String)
  Keys(reply: Subject(List(String)))
}

fn start_objects() -> Objects {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(fn(objects: Dict(String, BitArray), msg) {
      case msg {
        Get(key, reply) -> {
          process.send(reply, dict.get(objects, key))
          actor.continue(objects)
        }
        Put(key, body) -> actor.continue(dict.insert(objects, key, body))
        Delete(key) -> actor.continue(dict.delete(objects, key))
        Keys(reply) -> {
          process.send(reply, dict.keys(objects) |> list.sort(string.compare))
          actor.continue(objects)
        }
      }
    })
    |> actor.start
  started.data
}

/// A path-style S3 endpoint for bucket "huddy" that checks every request's
/// signature and payload hash, and pages listings two keys at a time.
fn start_fake_s3(port: Int, config: s3.Config) -> Objects {
  let objects = start_objects()
  let assert Ok(_) =
    mist.new(fn(req: Request(mist.Connection)) {
      let assert Ok(req) = mist.read_body(req, 10_000_000)
      fake_s3(objects, config, port, req)
      |> response.map(fn(body) { mist.Bytes(bytes_tree.from_bit_array(body)) })
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  objects
}

fn fake_s3(
  objects: Objects,
  config: s3.Config,
  port: Int,
  req: Request(BitArray),
) -> response.Response(BitArray) {
  let query = option.unwrap(req.query, "")
  let signed =
    s3.authorization(
      config,
      http.method_to_string(req.method) |> string.uppercase,
      req.path,
      query,
      [
        #("host", "127.0.0.1:" <> int_to_string(port)),
        #("x-amz-content-sha256", header(req, "x-amz-content-sha256")),
        #("x-amz-date", header(req, "x-amz-date")),
      ],
      header(req, "x-amz-content-sha256"),
      header(req, "x-amz-date"),
    )
  let payload_hash =
    crypto.hash(crypto.Sha256, req.body)
    |> bit_array.base16_encode
    |> string.lowercase
  let ok = response.new(200) |> response.set_body(<<>>)
  case
    header(req, "authorization") == signed
    && header(req, "x-amz-content-sha256") == payload_hash,
    req.method,
    req.path
  {
    False, _, _ ->
      response.new(403)
      |> response.set_body(<<
        "<Error><Code>SignatureDoesNotMatch</Code><Message>bad</Message></Error>":utf8,
      >>)
    True, http.Get, "/huddy" -> list_response(objects, query)
    True, http.Get, "/huddy/" <> key ->
      case process.call(objects, 1000, Get(decode(key), _)) {
        Ok(body) -> response.set_body(ok, body)
        Error(_) ->
          response.new(404)
          |> response.set_body(<<"<Error><Code>NoSuchKey</Code></Error>":utf8>>)
      }
    True, http.Put, "/huddy/" <> key -> {
      process.send(objects, Put(decode(key), req.body))
      ok
    }
    True, http.Delete, "/huddy/" <> key -> {
      process.send(objects, Delete(decode(key)))
      response.new(204) |> response.set_body(<<>>)
    }
    True, _, _ ->
      response.new(404)
      |> response.set_body(<<"<Error><Code>NoSuchBucket</Code></Error>":utf8>>)
  }
}

fn list_response(
  objects: Objects,
  query: String,
) -> response.Response(BitArray) {
  let params =
    string.split(query, "&")
    |> list.filter_map(string.split_once(_, "="))
    |> list.map(fn(pair) { #(pair.0, decode(pair.1)) })
  let prefix = list.key_find(params, "prefix") |> result.unwrap("")
  let after = list.key_find(params, "continuation-token") |> result.unwrap("")
  let keys =
    process.call(objects, 1000, Keys)
    |> list.filter(fn(k) {
      string.starts_with(k, prefix) && string.compare(k, after) == order.Gt
    })
  let page = list.take(keys, 2)
  let truncated = list.length(keys) > 2
  let body =
    "<ListBucketResult>"
    <> string.concat(
      list.map(page, fn(k) { "<Contents><Key>" <> k <> "</Key></Contents>" }),
    )
    <> case truncated, list.last(page) {
      True, Ok(last) ->
        "<IsTruncated>true</IsTruncated><NextContinuationToken>"
        <> last
        <> "</NextContinuationToken>"
      _, _ -> "<IsTruncated>false</IsTruncated>"
    }
    <> "</ListBucketResult>"
  response.new(200) |> response.set_body(bit_array.from_string(body))
}

@external(erlang, "uri_string", "percent_decode")
fn decode(text: String) -> String

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String

fn fake_config(port: Int) -> s3.Config {
  s3.Config(
    ..example_config(),
    scheme: http.Http,
    host: "127.0.0.1",
    port: Some(port),
    path_style: True,
  )
}

pub fn persist_round_trip_through_s3_test() {
  let port = 28_311
  let config = fake_config(port)
  let objects = start_fake_s3(port, config)
  let path = blob.Object(config, "huddy", "team a/huddy.json")
  let backups = blob.Object(config, "huddy", "team a/backups")
  // missing object and no backups: start empty
  let assert Ok(empty) = persist.load(path, backups)
  assert dict.is_empty(empty.items)

  let now = 1_791_622_800_000
  let #(s, a, _) = support.two_agents(now)
  let #(s, _) = state.create_item(s, a, support.goal("Ship S3 storage"), now)
  let assert Ok(size) = persist.write(path, s, 42)
  assert size > 0
  let assert Ok(loaded) = persist.load(path, backups)
  assert loaded.saved_at == 42
  assert loaded.items == s.items

  // backups are listed (across pages) and pruned
  let day = 86_400_000
  list.each([0, 1, 2, 3], fn(n) {
    let assert Ok(_) = persist.backup(backups, 3, s, now + n * day)
  })
  let assert Ok(names) = blob.list_dir(backups)
  assert names
    == ["huddy-20261011.json", "huddy-20261012.json", "huddy-20261013.json"]
  let assert Ok(Some(newest)) = persist.newest_backup(backups)
  assert string.starts_with(newest, "s3://huddy/team a/backups/huddy-")

  // the state object is gone but backups exist: refuse to start empty
  process.send(objects, Delete("team a/huddy.json"))
  let assert Error(message) = persist.load(path, backups)
  assert string.contains(message, "missing but backups exist")
}

pub fn s3_errors_are_reported_test() {
  let port = 28_312
  let _ = start_fake_s3(port, fake_config(port))
  let wrong_key =
    s3.Config(..fake_config(port), secret_access_key: "not-the-right-key")
  let path = blob.Object(wrong_key, "huddy", "huddy.json")
  let assert Error(message) = persist.load(path, blob.parent(path))
  assert string.contains(message, "SignatureDoesNotMatch")
  let assert Error(message) = persist.write(path, model.empty_state(), 1)
  assert string.contains(message, "HTTP 403")
  // a missing bucket is not a missing state file
  let elsewhere = blob.Object(fake_config(port), "other", "huddy.json")
  let local_backups = blob.File(support.tmp_dir() <> "/backups")
  let assert Error(message) = persist.load(elsewhere, local_backups)
  assert string.contains(message, "NoSuchBucket")
}
