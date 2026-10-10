//// Client for TypeSafe's decision-model API (`POST /v1/systemone`).
//// One request carries one `state` and many named questions.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import huddy/config

pub type Question {
  /// Yes/no: answered with P(yes).
  Noul(instructions: String)
  /// Pick one of the named choices (name -> description).
  Choice(instructions: String, criteria: List(#(String, String)))
  /// Rate on an ordered rubric (level 0, 1, 2, …).
  Score(instructions: String, criteria: List(String))
}

pub type Answer {
  NoulAnswer(p: Float)
  ChoiceAnswer(
    choice: String,
    confidence: Float,
    probabilities: Dict(String, Float),
  )
  ScoreAnswer(
    score: Float,
    confidence: Float,
    probabilities: Dict(String, Float),
  )
}

pub type Response {
  Response(
    answers: Dict(String, Answer),
    input_tokens: Int,
    output_tokens: Int,
    raw: String,
  )
}

/// The decision-model interface the rest of Huddy depends on. Swapping
/// providers (or faking it in tests) means supplying another function.
pub type Ask =
  fn(Json, List(#(String, Question))) -> Result(Response, String)

pub fn question_json(q: Question) -> Json {
  case q {
    Noul(instructions) ->
      json.object([
        #("type", json.string("noul")),
        #("instructions", json.string(instructions)),
      ])
    Choice(instructions, criteria) ->
      json.object([
        #("type", json.string("choice")),
        #("instructions", json.string(instructions)),
        #(
          "criteria",
          json.object(list.map(criteria, fn(c) { #(c.0, json.string(c.1)) })),
        ),
      ])
    Score(instructions, criteria) ->
      json.object([
        #("type", json.string("score")),
        #("instructions", json.string(instructions)),
        #("criteria", json.array(criteria, json.string)),
      ])
  }
}

pub fn request_json(
  model: String,
  state: Json,
  questions: List(#(String, Question)),
) -> Json {
  json.object([
    #("model", json.string(model)),
    #("state", state),
    #(
      "questions",
      json.object(list.map(questions, fn(q) { #(q.0, question_json(q.1)) })),
    ),
  ])
}

fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn answer_decoder() -> Decoder(Answer) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "noul" -> {
      use p <- decode.field("noul", number())
      decode.success(NoulAnswer(p))
    }
    "choice" -> {
      use choice <- decode.field("choice", decode.string)
      use confidence <- decode.field("confidence", number())
      use probabilities <- decode.optional_field(
        "probabilities",
        dict.new(),
        decode.dict(decode.string, number()),
      )
      decode.success(ChoiceAnswer(choice:, confidence:, probabilities:))
    }
    "score" -> {
      use score <- decode.field("score", number())
      use confidence <- decode.optional_field("confidence", 0.0, number())
      use probabilities <- decode.optional_field(
        "probabilities",
        dict.new(),
        decode.dict(decode.string, number()),
      )
      decode.success(ScoreAnswer(score:, confidence:, probabilities:))
    }
    other -> decode.failure(NoulAnswer(0.0), "answer type, got " <> other)
  }
}

pub fn decode_response(body: String) -> Result(Response, String) {
  let decoder = {
    use answers <- decode.field(
      "answers",
      decode.dict(decode.string, answer_decoder()),
    )
    use #(input, output) <- decode.optional_field("usage", #(0, 0), {
      use i <- decode.optional_field("input_tokens", 0, decode.int)
      use o <- decode.optional_field("output_tokens", 0, decode.int)
      decode.success(#(i, o))
    })
    decode.success(Response(
      answers:,
      input_tokens: input,
      output_tokens: output,
      raw: body,
    ))
  }
  json.parse(body, decoder)
  |> result.replace_error("unexpected response from the decision model")
}

/// The HTTP client for the configured provider.
pub fn client(cfg: config.DecisionModel) -> Ask {
  fn(state: Json, questions: List(#(String, Question))) {
    let body = request_json(cfg.model, state, questions) |> json.to_string
    use req <- result.try(
      request.to(cfg.base_url <> "/v1/systemone")
      |> result.replace_error("invalid decision_model.base_url"),
    )
    let req =
      req
      |> request.set_method(http.Post)
      |> request.set_header("authorization", "Bearer " <> cfg.api_key)
      |> request.set_header("content-type", "application/json")
      |> request.set_header("accept", "application/json")
      |> request.set_body(body)
    use resp <- result.try(
      httpc.configure()
      |> httpc.timeout(cfg.timeout_ms)
      |> httpc.dispatch(req)
      |> result.map_error(fn(e) {
        case e {
          httpc.ResponseTimeout -> "decision model timed out"
          httpc.FailedToConnect(..) -> "cannot connect to the decision model"
          httpc.InvalidUtf8Response ->
            "invalid response from the decision model"
        }
      }),
    )
    case resp.status {
      200 -> decode_response(resp.body)
      status ->
        Error(
          "decision model returned HTTP "
          <> int.to_string(status)
          <> ": "
          <> resp.body,
        )
    }
  }
}

/// Probability of a choice (0.0 when absent).
pub fn probability(answer: Answer, choice: String) -> Float {
  case answer {
    ChoiceAnswer(probabilities:, ..) | ScoreAnswer(probabilities:, ..) ->
      dict.get(probabilities, choice) |> result.unwrap(0.0)
    NoulAnswer(_) -> 0.0
  }
}
