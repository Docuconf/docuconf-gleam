//// The orders service's configuration, declared with docuconf. The same
//// declaration loads the environment at boot and exports `contract.cue`.

import docuconf
import docuconf/duration.{type Duration}
import gleam/json.{type Json}
import gleam/list
import wisp

pub type Config {
  Config(
    port: Int,
    log_level: wisp.LogLevel,
    database_url: String,
    allowed_origins: List(String),
    request_timeout: Duration,
    worker_count: Int,
  )
}

const log_levels = [
  #("debug", wisp.DebugLevel),
  #("info", wisp.InfoLevel),
  #("warn", wisp.WarningLevel),
  #("error", wisp.ErrorLevel),
]

pub fn spec() -> docuconf.Spec(Config) {
  use port <- docuconf.env(
    docuconf.int("PORT", "HTTP listen port")
    |> docuconf.min_int(1)
    |> docuconf.max_int(65_535)
    |> docuconf.default(8080),
  )
  use log_level <- docuconf.env(
    docuconf.enum("LOG_LEVEL", "Minimum log level emitted", log_levels)
    |> docuconf.default(wisp.InfoLevel),
  )
  // A secret is exported as `secret: true`: the platform supplies it from a
  // Secret, and docuconf never prints its value.
  use database_url <- docuconf.env(
    docuconf.url("DATABASE_URL", "Primary Postgres connection string")
    |> docuconf.schemes(["postgres"])
    |> docuconf.secret
    |> docuconf.required,
  )
  use allowed_origins <- docuconf.env(
    docuconf.string_list(
      "ALLOWED_ORIGINS",
      "Origins allowed to call the API (CORS), comma-separated",
      separator: ",",
    )
    |> docuconf.min_items(1)
    |> docuconf.default(["http://localhost:3000"]),
  )
  use request_timeout <- docuconf.env(
    docuconf.duration("REQUEST_TIMEOUT", "Timeout for one API request")
    |> docuconf.min_duration("1s")
    |> docuconf.max_duration("5m")
    |> docuconf.default(duration.seconds(30)),
  )
  use worker_count <- docuconf.env(
    docuconf.int("WORKER_COUNT", "Background workers that process orders")
    |> docuconf.min_int(1)
    |> docuconf.max_int(64)
    |> docuconf.default(4),
  )
  docuconf.succeed(Config(
    port:,
    log_level:,
    database_url:,
    allowed_origins:,
    request_timeout:,
    worker_count:,
  ))
}

/// The configuration as JSON, with the secret redacted.
pub fn to_json(config: Config) -> Json {
  let level = case list.find(log_levels, fn(l) { l.1 == config.log_level }) {
    Ok(#(name, _)) -> name
    Error(Nil) -> "info"
  }
  json.object([
    #("port", json.int(config.port)),
    #("log_level", json.string(level)),
    #("database_url", json.string("***")),
    #("allowed_origins", json.array(config.allowed_origins, json.string)),
    #(
      "request_timeout",
      json.string(duration.to_string(config.request_timeout)),
    ),
    #("worker_count", json.int(config.worker_count)),
  ])
}
