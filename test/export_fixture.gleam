//// The shared export fixture (docuconf-go conformance/export/fixture.yaml,
//// SPEC §11.2 item 3), declared with this SDK's own API. export_fixture_test
//// exports it and compares it with conformance/export/golden.cue through
//// `docuconf conformance export`.

import docuconf.{type CaBundle, type KeySet, type Secret, type Tls, type Watched}
import docuconf/duration.{type Duration}
import docuconf/json
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}

pub type LogLevel {
  Debug
  Info
  Warn
  Error
}

pub type RateLimits {
  RateLimits(per_minute: Int, burst: Option(Int))
}

pub type Settings {
  Settings(name: String, replicas: Int, tags: List(String))
}

pub type Fixture {
  Fixture(
    app_name: String,
    database_url: Secret(String),
    port: Int,
    trace_ratio: Float,
    debug: Bool,
    request_timeout: Duration,
    log_level: LogLevel,
    allowed_origins: Option(List(String)),
    shards: Option(List(Int)),
    webhook_keys: Option(KeySet),
    rate_limits: RateLimits,
    old_port: Option(Int),
    partner_password: Option(Secret(String)),
    settings: Watched(Settings),
    rules: Option(Settings),
    flags: Option(Settings),
    serving_tls: Option(Watched(Tls)),
    trust: Option(CaBundle),
    partner: Option(String),
    licence: Option(String),
    geoip: Option(String),
    geo_db: Option(String),
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
    ..case r.burst {
      Some(b) -> [#("burst", json.int(b))]
      None -> []
    }
  ])
}

fn rate_limits_schema() -> json.Json {
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

fn settings_decoder() -> decode.Decoder(Settings) {
  use name <- decode.field("name", decode.string)
  use replicas <- decode.field("replicas", decode.int)
  use tags <- decode.optional_field("tags", [], decode.list(decode.string))
  decode.success(Settings(name:, replicas:, tags:))
}

fn settings_schema() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("required", json.array(["name", "replicas"], json.string)),
    #("additionalProperties", json.bool(False)),
    #(
      "properties",
      json.object([
        #(
          "name",
          json.object([
            #("type", json.string("string")),
            #("minLength", json.int(1)),
          ]),
        ),
        #(
          "replicas",
          json.object([
            #("type", json.string("integer")),
            #("minimum", json.int(1)),
          ]),
        ),
        #(
          "tags",
          json.object([
            #("type", json.string("array")),
            #("items", json.object([#("type", json.string("string"))])),
          ]),
        ),
      ]),
    ),
  ])
}

pub fn spec() -> docuconf.Spec(Fixture) {
  use app_name <- docuconf.env(
    docuconf.string("APP_NAME", "Service name, used in logs and metrics")
    |> docuconf.details("Lower case, as a DNS label allows.")
    |> docuconf.min_length(2)
    |> docuconf.max_length(40)
    |> docuconf.pattern("^[a-z][a-z0-9-]*$")
    |> docuconf.group("general")
    |> docuconf.examples(["orders", "billing"])
    |> docuconf.config_key("App:Name")
    |> docuconf.default("orders"),
  )
  use database_url <- docuconf.env(
    docuconf.url("DATABASE_URL", "Primary Postgres connection string")
    |> docuconf.schemes(["postgres", "postgresql"])
    |> docuconf.max_length(2048)
    |> docuconf.group("database")
    |> docuconf.secret
    |> docuconf.required,
  )
  use port <- docuconf.env(
    docuconf.int("PORT", "HTTP listen port")
    |> docuconf.min_int(1)
    |> docuconf.max_int(65_535)
    |> docuconf.default(8080),
  )
  use trace_ratio <- docuconf.env(
    docuconf.float("TRACE_RATIO", "Fraction of requests traced")
    |> docuconf.min_float(0.0)
    |> docuconf.max_float(1.0)
    |> docuconf.default(0.25),
  )
  use debug <- docuconf.env(
    docuconf.bool("DEBUG", "Serve the debug endpoints")
    |> docuconf.default(False),
  )
  use request_timeout <- docuconf.env(
    docuconf.duration("REQUEST_TIMEOUT", "Upstream request timeout")
    |> docuconf.min_duration(duration.seconds(1))
    |> docuconf.max_duration(duration.minutes(5))
    |> docuconf.default(duration.seconds(90)),
  )
  use log_level <- docuconf.env(
    docuconf.enum("LOG_LEVEL", "Minimum log level", [
      #("debug", Debug),
      #("info", Info),
      #("warn", Warn),
      #("error", Error),
    ])
    |> docuconf.default(Info),
  )
  use allowed_origins <- docuconf.env(
    docuconf.string_list(
      "ALLOWED_ORIGINS",
      "CORS origins allowed to call the API",
      separator: ";",
    )
    |> docuconf.min_items(1)
    |> docuconf.max_items(5)
    |> docuconf.item_min_length(1)
    |> docuconf.item_max_length(255)
    |> docuconf.optional,
  )
  use shards <- docuconf.env(
    docuconf.int_list("SHARDS", "Shards this instance owns", separator: ",")
    |> docuconf.item_min(0)
    |> docuconf.item_max(1023)
    |> docuconf.optional,
  )
  use webhook_keys <- docuconf.env(
    docuconf.key_set("WEBHOOK_KEYS", "Keys that verify webhook signatures")
    |> docuconf.key_min_length(32)
    |> docuconf.key_max_length(256)
    |> docuconf.optional,
  )
  use rate_limits <- docuconf.env(
    docuconf.json(
      "RATE_LIMITS",
      "Per-client rate limits",
      decoder: rate_limits_decoder(),
      encode: encode_rate_limits,
    )
    |> docuconf.schema(rate_limits_schema())
    |> docuconf.max_length(1024)
    |> docuconf.default(RateLimits(per_minute: 60, burst: None)),
  )
  use old_port <- docuconf.env(
    docuconf.int("OLD_PORT", "Port the service used to listen on")
    |> docuconf.deprecated("Use PORT instead")
    |> docuconf.replaced_by("PORT")
    |> docuconf.optional,
  )
  use partner_password <- docuconf.env(
    docuconf.string("PARTNER_PASSWORD", "Password of the partner keystore")
    |> docuconf.secret
    |> docuconf.optional,
  )
  use settings <- docuconf.file(
    docuconf.config_file(
      "settings",
      "Application settings",
      path: "/etc/app/settings/settings.json",
      decoder: settings_decoder(),
    )
    |> docuconf.file_schema(settings_schema())
    |> docuconf.path_env("SETTINGS_FILE")
    |> docuconf.max_size(65_536)
    |> docuconf.file_group("general")
    |> docuconf.reload_watch
    |> docuconf.file_required,
  )
  use rules <- docuconf.file(
    docuconf.config_file_with(
      "rules",
      "Routing rules",
      path: "/etc/app/rules/rules.yaml",
      format: "yaml",
      parse: docuconf.parse_yaml,
      decoder: settings_decoder(),
    )
    |> docuconf.file_schema(settings_schema())
    |> docuconf.file_optional,
  )
  use flags <- docuconf.file(
    docuconf.config_file_with(
      "flags",
      "Feature defaults",
      path: "/etc/app/flags/flags.toml",
      format: "toml",
      parse: docuconf.parse_toml,
      decoder: settings_decoder(),
    )
    |> docuconf.file_schema(settings_schema())
    |> docuconf.file_optional,
  )
  use serving_tls <- docuconf.file(
    docuconf.tls(
      "serving-tls",
      "Certificate the service serves HTTPS with",
      path: "/etc/app/tls",
    )
    |> docuconf.dns_names(["app.example.test", "api.example.test"])
    |> docuconf.key_algorithms([docuconf.Ecdsa, docuconf.Ed25519])
    |> docuconf.min_remaining(duration.hours(720))
    |> docuconf.require_ca
    |> docuconf.reload_watch
    |> docuconf.file_optional,
  )
  use trust <- docuconf.file(
    docuconf.ca_bundle(
      "trust",
      "CAs the service trusts",
      path: "/etc/app/trust/bundle.pem",
    )
    |> docuconf.min_certificates(2)
    |> docuconf.file_optional,
  )
  use partner <- docuconf.file(
    docuconf.keystore(
      "partner",
      "Client certificate for the partner API",
      path: "/etc/app/partner/keystore.p12",
      format: docuconf.Pkcs12,
      password_var: Some("PARTNER_PASSWORD"),
    )
    |> docuconf.file_optional,
  )
  use licence <- docuconf.file(
    docuconf.text(
      "licence",
      "Licence key",
      path: "/etc/app/licence/licence.key",
    )
    |> docuconf.text_min_length(8)
    |> docuconf.text_max_length(64)
    |> docuconf.text_pattern("^[A-Z0-9-]+\\n?$")
    |> docuconf.file_optional,
  )
  use geoip <- docuconf.file(
    docuconf.binary("geoip", "GeoIP database", path: "/data/geoip/geoip.mmdb")
    |> docuconf.max_size(134_217_728)
    |> docuconf.file_deprecated("Use geo-db instead")
    |> docuconf.file_replaced_by("geo-db")
    |> docuconf.file_optional,
  )
  use geo_db <- docuconf.file(
    docuconf.binary(
      "geo-db",
      "City-level location database",
      path: "/data/geo-db/geo.mmdb",
    )
    |> docuconf.file_optional,
  )
  use v <- docuconf.build
  Fixture(
    app_name: app_name(v),
    database_url: database_url(v),
    port: port(v),
    trace_ratio: trace_ratio(v),
    debug: debug(v),
    request_timeout: request_timeout(v),
    log_level: log_level(v),
    allowed_origins: allowed_origins(v),
    shards: shards(v),
    webhook_keys: webhook_keys(v),
    rate_limits: rate_limits(v),
    old_port: old_port(v),
    partner_password: partner_password(v),
    settings: settings(v),
    rules: rules(v),
    flags: flags(v),
    serving_tls: serving_tls(v),
    trust: trust(v),
    partner: partner(v),
    licence: licence(v),
    geoip: geoip(v),
    geo_db: geo_db(v),
  )
}
