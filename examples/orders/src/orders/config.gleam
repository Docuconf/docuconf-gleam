//// The orders service's configuration, declared with docuconf. The same
//// declaration loads the environment at boot and exports `contract.cue`.

import docuconf.{type Secret}
import docuconf/duration.{type Duration}
import gleam/json.{type Json}
import gleam/result
import wisp

pub type Config {
  Config(
    port: Int,
    log_level: wisp.LogLevel,
    database_url: Secret(String),
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
  // Secret. docuconf never prints its value, and the app gets a
  // `docuconf.Secret`, which prints redacted; `docuconf.reveal` reads it.
  use database_url <- docuconf.env(
    docuconf.url("DATABASE_URL", "Primary Postgres connection string")
    |> docuconf.schemes(["postgres"])
    // At most 2048 characters; a longer URL fails the boot with out_of_range.
    |> docuconf.max_length(2048)
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
    // Longer docs for `docuconf docs`, in Markdown. Never read at runtime.
    |> docuconf.details(
      "Raise it when clients upload large order batches. Keep it below the
load balancer's idle timeout, or the client sees a reset rather than a
`504`.",
    )
    |> docuconf.min_duration(duration.seconds(1))
    |> docuconf.max_duration(duration.minutes(5))
    |> docuconf.default(duration.seconds(30)),
  )
  use worker_count <- docuconf.env(
    docuconf.int("WORKER_COUNT", "Background workers that process orders")
    |> docuconf.min_int(1)
    |> docuconf.max_int(64)
    |> docuconf.default(4),
  )
  // Each `use` above bound a handle; `build` reads the values once they
  // have all loaded and passed their checks.
  use v <- docuconf.build
  Config(
    port: port(v),
    log_level: log_level(v),
    database_url: database_url(v),
    allowed_origins: allowed_origins(v),
    request_timeout: request_timeout(v),
    worker_count: worker_count(v),
  )
}

/// The configuration as JSON, with the secret redacted.
pub fn to_json(config: Config) -> Json {
  json.object([
    #("port", json.int(config.port)),
    #(
      "log_level",
      json.string(
        docuconf.enum_name(log_levels, config.log_level)
        |> result.unwrap("info"),
      ),
    ),
    #("database_url", json.string("***")),
    #("allowed_origins", json.array(config.allowed_origins, json.string)),
    #(
      "request_timeout",
      json.string(duration.to_string(config.request_timeout)),
    ),
    #("worker_count", json.int(config.worker_count)),
  ])
}
