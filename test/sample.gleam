//// Every variable type and every file type, for the export golden test.

import docuconf.{type CaBundle, type Secret, type Tls}
import docuconf/duration.{type Duration}
import docuconf/json
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}

pub type LogLevel {
  LogDebug
  LogInfo
  LogWarn
  LogError
}

pub type RateLimits {
  RateLimits(per_minute: Int, burst: Option(Int))
}

pub type Route {
  Route(match: String, upstream: String, timeout: Option(String))
}

pub type Sample {
  Sample(
    database_url: Secret(String),
    port: Int,
    gomemlimit: Option(Int),
    sample_rate: Float,
    debug: Bool,
    request_timeout: Duration,
    public_url: String,
    log_level: LogLevel,
    allowed_origins: List(String),
    worker_ports: Option(List(Int)),
    rate_limits: Option(RateLimits),
    region: String,
    keystore_password: Option(Secret(String)),
    routes: List(Route),
    serving_tls: Tls,
    upstream_ca: Option(CaBundle),
    partner_keystore: Option(String),
    license: String,
    geoip: Option(String),
  )
}

fn rate_limits_decoder() -> decode.Decoder(RateLimits) {
  use per_minute <- decode.field("perMinute", decode.int)
  use burst <- decode.optional_field("burst", None, decode.optional(decode.int))
  decode.success(RateLimits(per_minute:, burst:))
}

fn encode_rate_limits(r: RateLimits) -> json.Json {
  json.object([
    #("perMinute", json.int(r.per_minute)),
    #("burst", case r.burst {
      Some(b) -> json.int(b)
      None -> json.null()
    }),
  ])
}

pub fn rate_limits_schema() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("required", json.array(["perMinute"], json.string)),
    #("additionalProperties", json.bool(False)),
    #(
      "properties",
      json.object([
        #(
          "perMinute",
          json.object([
            #("type", json.string("integer")),
            #("minimum", json.int(1)),
          ]),
        ),
        #(
          "burst",
          json.object([
            #("type", json.string("integer")),
            #("minimum", json.int(0)),
          ]),
        ),
      ]),
    ),
  ])
}

pub fn routes_decoder() -> decode.Decoder(List(Route)) {
  let route = {
    use match <- decode.field("match", decode.string)
    use upstream <- decode.field("upstream", decode.string)
    use timeout <- decode.optional_field(
      "timeout",
      None,
      decode.optional(decode.string),
    )
    decode.success(Route(match:, upstream:, timeout:))
  }
  use routes <- decode.field("routes", decode.list(route))
  decode.success(routes)
}

fn routes_schema() -> json.Json {
  let str = fn(pattern) {
    json.object([
      #("type", json.string("string")),
      #("pattern", json.string(pattern)),
    ])
  }
  json.object([
    #("type", json.string("object")),
    #("required", json.array(["routes"], json.string)),
    #("additionalProperties", json.bool(False)),
    #(
      "properties",
      json.object([
        #(
          "routes",
          json.object([
            #("type", json.string("array")),
            #("minItems", json.int(1)),
            #(
              "items",
              json.object([
                #("type", json.string("object")),
                #("required", json.array(["match", "upstream"], json.string)),
                #("additionalProperties", json.bool(False)),
                #(
                  "properties",
                  json.object([
                    #("match", str("^/")),
                    #("upstream", str("^https?://")),
                    #(
                      "timeout",
                      json.object([#("type", json.string("string"))]),
                    ),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

pub fn spec() -> docuconf.Spec(Sample) {
  use database_url <- docuconf.env(
    docuconf.url("DATABASE_URL", "Primary Postgres connection string")
    |> docuconf.schemes(["postgres", "postgresql"])
    |> docuconf.secret
    |> docuconf.required,
  )
  use port <- docuconf.env(
    docuconf.int("PORT", "HTTP listen port")
    |> docuconf.min_int(1)
    |> docuconf.max_int(65_535)
    |> docuconf.default(8080),
  )
  use gomemlimit <- docuconf.env(
    docuconf.int("GOMEMLIMIT", "Soft memory limit, in bytes")
    |> docuconf.min_int(1)
    // The largest integer the JavaScript target holds exactly, so the
    // export is the same on both targets.
    |> docuconf.max_int(9_007_199_254_740_991)
    |> docuconf.optional,
  )
  use sample_rate <- docuconf.env(
    docuconf.float("SAMPLE_RATE", "Fraction of requests traced")
    |> docuconf.min_float(0.0)
    |> docuconf.max_float(1.0)
    |> docuconf.default(0.25),
  )
  use debug <- docuconf.env(
    docuconf.bool("DEBUG", "Verbose request logging") |> docuconf.default(False),
  )
  use request_timeout <- docuconf.env(
    docuconf.duration("REQUEST_TIMEOUT", "Upstream request timeout")
    |> docuconf.min_duration(duration.seconds(1))
    |> docuconf.max_duration(duration.minutes(5))
    |> docuconf.default(duration.seconds(30)),
  )
  use public_url <- docuconf.env(
    docuconf.url("PUBLIC_URL", "Externally visible base URL")
    |> docuconf.schemes(["https"])
    |> docuconf.required,
  )
  use log_level <- docuconf.env(
    docuconf.enum("LOG_LEVEL", "Minimum log level emitted", [
      #("debug", LogDebug),
      #("info", LogInfo),
      #("warn", LogWarn),
      #("error", LogError),
    ])
    |> docuconf.group("logging")
    |> docuconf.default(LogInfo),
  )
  use allowed_origins <- docuconf.env(
    docuconf.string_list(
      "ALLOWED_ORIGINS",
      "CORS origins allowed to call the API",
      separator: ",",
    )
    |> docuconf.min_items(1)
    |> docuconf.max_items(10)
    |> docuconf.required,
  )
  use worker_ports <- docuconf.env(
    docuconf.int_list("WORKER_PORTS", "Ports the workers bind", separator: ";")
    |> docuconf.item_min(1)
    |> docuconf.item_max(65_535)
    |> docuconf.optional,
  )
  use rate_limits <- docuconf.env(
    docuconf.json(
      "RATE_LIMITS",
      "Default per-client rate limits",
      decoder: rate_limits_decoder(),
      encode: encode_rate_limits,
    )
    |> docuconf.schema(rate_limits_schema())
    |> docuconf.optional,
  )
  use region <- docuconf.env(
    docuconf.string("REGION", "Cloud region the service runs in")
    |> docuconf.examples(["eu-west-1"])
    |> docuconf.min_length(4)
    |> docuconf.max_length(32)
    |> docuconf.pattern("^[a-z]{2}-[a-z]+-[0-9]$")
    |> docuconf.required,
  )
  use keystore_password <- docuconf.env(
    docuconf.string("KEYSTORE_PASSWORD", "Password for the partner keystore")
    |> docuconf.min_length(1)
    |> docuconf.secret
    |> docuconf.optional,
  )
  use routes <- docuconf.file(
    docuconf.config_file(
      "routes",
      "Routing table: path prefixes and their upstreams",
      path: "/etc/gateway/routes/routes.json",
      decoder: routes_decoder(),
    )
    |> docuconf.path_env("ROUTES_FILE")
    |> docuconf.max_size(65_536)
    |> docuconf.file_schema(routes_schema())
    |> docuconf.file_required,
  )
  use serving_tls <- docuconf.file(
    docuconf.tls(
      "serving-tls",
      "Certificate the gateway serves HTTPS with",
      path: "/etc/gateway/tls",
    )
    |> docuconf.dns_names(["gateway.internal", "api.example.com"])
    |> docuconf.key_algorithms([docuconf.Ecdsa, docuconf.Rsa])
    |> docuconf.min_remaining(duration.hours(720))
    |> docuconf.require_ca
    |> docuconf.file_required,
  )
  use upstream_ca <- docuconf.file(
    docuconf.ca_bundle(
      "upstream-ca",
      "Private CAs the gateway trusts for upstream TLS",
      path: "/etc/gateway/ca/bundle.pem",
    )
    |> docuconf.path_env("SSL_CERT_FILE")
    |> docuconf.file_optional,
  )
  use partner_keystore <- docuconf.file(
    docuconf.keystore(
      "partner-keystore",
      "Client certificate for mTLS to the partner API",
      path: "/etc/gateway/partner/keystore.p12",
      format: docuconf.Pkcs12,
      password_var: Some("KEYSTORE_PASSWORD"),
    )
    |> docuconf.file_optional,
  )
  use license <- docuconf.file(
    docuconf.text(
      "license",
      "Gateway licence key",
      path: "/etc/gateway/license/license.key",
    )
    |> docuconf.text_pattern("^[A-Z0-9]{5}(-[A-Z0-9]{5}){3}\\n?$")
    |> docuconf.file_required,
  )
  use geoip <- docuconf.file(
    docuconf.binary(
      "geoip",
      "GeoIP database for country-based routing",
      path: "/data/geoip/GeoLite2-City.mmdb",
    )
    |> docuconf.max_size(134_217_728)
    |> docuconf.file_optional,
  )
  use v <- docuconf.build
  Sample(
    database_url: database_url(v),
    port: port(v),
    gomemlimit: gomemlimit(v),
    sample_rate: sample_rate(v),
    debug: debug(v),
    request_timeout: request_timeout(v),
    public_url: public_url(v),
    log_level: log_level(v),
    allowed_origins: allowed_origins(v),
    worker_ports: worker_ports(v),
    rate_limits: rate_limits(v),
    region: region(v),
    keystore_password: keystore_password(v),
    routes: routes(v),
    serving_tls: serving_tls(v),
    upstream_ca: upstream_ca(v),
    partner_keystore: partner_keystore(v),
    license: license(v),
    geoip: geoip(v),
  )
}
