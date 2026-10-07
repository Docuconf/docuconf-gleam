import docuconf
import gleam/erlang/process
import gleam/http
import gleam/json
import gleam/string
import mist
import orders/config.{type Config, to_json}
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
    _, _ -> wisp.not_found()
  }
}
