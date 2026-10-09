//// The README's code that is not taken from examples/orders, compiled on
//// both targets. `readme_test` checks that every `gleam` block of the
//// README appears, character for character, in this file or in the
//// example app.

import docuconf.{type KeySet, type Secret}
import docuconf/contract_first
import docuconf/duration
import docuconf/json
import gleam/dict
import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/result
import gleam/uri.{type Uri}

pub fn shards() -> docuconf.Spec(Option(List(Int))) {
  use shards <- docuconf.env(
    docuconf.int_list("SHARDS", "Shard ids this instance owns", separator: ",")
    |> docuconf.item_min(0)
    |> docuconf.item_max(1023)
    |> docuconf.optional,
  )
  docuconf.build(shards)
}

pub fn database() -> docuconf.Spec(Uri) {
  use database_url <- docuconf.env(
    docuconf.url("DATABASE_URL", "Postgres connection string")
    |> docuconf.required
    |> docuconf.try_map(fn(s) {
      uri.parse(s) |> result.replace_error("is not a parseable URI")
    }),
  )
  docuconf.build(database_url)
}

pub type Cache {
  Cache(enabled: Bool, url: Option(String))
}

pub fn cache_spec() -> docuconf.Spec(Cache) {
  use enabled <- docuconf.env(
    docuconf.bool("CACHE_ENABLED", "Use the Redis cache")
    |> docuconf.default(False),
  )
  use url <- docuconf.env(
    docuconf.url("REDIS_URL", "Redis connection string")
    |> docuconf.optional,
  )
  use v <- docuconf.build
  Cache(enabled: enabled(v), url: url(v))
}

pub fn with_cache() -> docuconf.Spec(#(Int, Cache)) {
  use port <- docuconf.env(
    docuconf.int("PORT", "HTTP listen port") |> docuconf.default(8080),
  )
  use cache <- docuconf.include(cache_spec())
  use v <- docuconf.build
  #(port(v), cache(v))
}

pub type Pricing {
  Pricing(currency: String)
}

pub type Files {
  Files(pricing: Pricing, tls: docuconf.Tls, license: Secret(String))
}

pub fn files() -> docuconf.Spec(Files) {
  use pricing <- docuconf.file(
    docuconf.config_file(
      "pricing",
      "Pricing rules: currency and discount tiers",
      path: "/etc/orders/pricing/pricing.json",
      decoder: {
        use currency <- decode.field("currency", decode.string)
        decode.success(Pricing(currency:))
      },
    )
    |> docuconf.file_schema(json.object([#("type", json.string("object"))]))
    |> docuconf.file_required,
  )
  use tls <- docuconf.file(
    docuconf.tls(
      "serving-tls",
      "Certificate the API serves HTTPS with",
      path: "/etc/orders/tls",
    )
    |> docuconf.dns_names(["orders.internal"])
    |> docuconf.min_remaining(duration.hours(720))
    |> docuconf.file_required,
  )
  use license <- docuconf.file(
    docuconf.text("license", "Licence key", path: "/etc/orders/license/key")
    |> docuconf.secret_file
    |> docuconf.file_required,
  )
  use v <- docuconf.build
  Files(pricing: pricing(v), tls: tls(v), license: license(v))
}

pub fn contract_first_port(contract_json: String) -> Int {
  let assert Ok(values) = contract_first.load(contract_json, docuconf.options())
  let assert Ok(contract_first.IntValue(port)) = dict.get(values, "PORT")
  port
}

pub fn api_keys() -> docuconf.Spec(KeySet) {
  use keys <- docuconf.env(
    docuconf.key_set("API_KEYS", "Keys that callers present")
    |> docuconf.key_min_length(32)
    |> docuconf.key_max_length(256)
    |> docuconf.required,
  )
  docuconf.build(keys)
}

pub fn authorized(keys: KeySet, presented: String) -> Bool {
  docuconf.contains(keys, presented)
}
