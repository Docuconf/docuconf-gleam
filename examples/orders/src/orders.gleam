import docuconf
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/json
import gleam/option
import gleam/result
import gleam/string
import mist
import orders/config.{type Config, to_json}
import orders/webhook
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn main() -> Nil {
  // docuconf checks the whole environment before the app starts. On a
  // problem it prints every one at once, each with a stable code, and
  // exits with status 1.
  let config = docuconf.load_or_exit(config.spec())

  wisp.configure_logger()
  wisp.set_logger_level(config.log_level)
  // The secret prints as Secret(//fn() { ... }), never its value.
  wisp.log_info("config: " <> string.inspect(config))
  let assert Ok(_) =
    wisp_mist.handler(handle(_, config), wisp.random_string(64))
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(config.port)
    |> mist.start
  process.sleep_forever()
}

fn handle(req: Request, config: Config) -> Response {
  use <- wisp.log_request(req)
  case req.method, wisp.path_segments(req) {
    http.Get, ["healthz"] -> wisp.ok() |> wisp.string_body("ok")
    http.Get, ["config"] ->
      to_json(config) |> json.to_string |> wisp.json_response(200)
    http.Post, ["webhooks", "payments"] -> payment(req, config)
    _, _ -> wisp.not_found()
  }
}

// Payment webhooks, signed with any key in WEBHOOK_KEYS (see config.gleam
// for how to rotate it).
fn payment(req: Request, config: Config) -> Response {
  use body <- wisp.require_bit_array_body(req)
  let keys = case config.webhook_keys {
    option.Some(keys) -> docuconf.reveal(keys)
    option.None -> []
  }
  let signature = request.get_header(req, "x-signature") |> result.unwrap("")
  case webhook.verify(keys, body, signature) {
    True -> wisp.no_content()
    False -> wisp.response(401) |> wisp.string_body("bad signature")
  }
}
