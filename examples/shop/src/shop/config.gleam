//// The shop's configuration, read through contract-first mode: the contract
//// is contract.json, and this module turns the values docuconf checked into
//// a typed `Config`.

import docuconf.{type Secret}
import docuconf/contract_first.{
  type Value, Absent, BoolValue, IntValue, ListValue, SecretValue, StringValue,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Config {
  Config(
    role: Role,
    database_url: Secret(String),
    log_format: String,
    log_schema_url: Option(String),
  )
}

/// What `DOCUCONF_ROLE` selects, with the inputs only that role reads.
pub type Role {
  Web(port: Int, allowed_origins: List(String))
  /// `webhook_signing_key` is set when `WEBHOOKS_ENABLED` is true: the
  /// contract then requires the key file.
  Worker(queues: List(String), webhook_signing_key: Option(Secret(String)))
}

/// Checks the environment and files (as `options` says where to read them)
/// against the contract, given as JSON text. On a bad environment the error
/// lists every problem; `docuconf.describe` formats it.
pub fn load(
  contract: String,
  options: docuconf.Options,
) -> Result(Config, docuconf.Error) {
  use values <- result.try(contract_first.load(contract, options))
  from_values(values)
  |> result.map_error(fn(problem) {
    docuconf.InvalidDeclaration(["contract.json: " <> problem])
  })
}

/// The one line the shop prints at startup.
pub fn summary(config: Config) -> String {
  case config.role {
    Web(port:, allowed_origins:) ->
      "shop web: port "
      <> int.to_string(port)
      <> ", origins "
      <> string.join(allowed_origins, ",")
    Worker(queues:, webhook_signing_key:) ->
      "shop worker: queues "
      <> string.join(queues, ",")
      <> ", webhooks "
      <> case webhook_signing_key {
        Some(_) -> "on"
        None -> "off"
      }
  }
}

// ---- from the checked values ---------------------------------------------------

// docuconf has checked every value against the contract, so a wrong shape
// here means contract.json no longer says what this module expects.
fn from_values(values: Dict(String, Value)) -> Result(Config, String) {
  use role <- result.try(string(values, "DOCUCONF_ROLE"))
  use role <- result.try(case role {
    "web" -> {
      use port <- result.try(int(values, "PORT"))
      use origins <- result.map(strings(values, "ALLOWED_ORIGINS"))
      Web(port:, allowed_origins: origins)
    }
    "worker" -> {
      use queues <- result.try(strings(values, "QUEUES"))
      use enabled <- result.try(bool(values, "WEBHOOKS_ENABLED"))
      use key <- result.map(case enabled {
        True -> secret(values, "webhook-signing-key") |> result.map(Some)
        False -> Ok(None)
      })
      Worker(queues:, webhook_signing_key: key)
    }
    other -> Error("unknown role " <> other)
  })
  use database_url <- result.try(secret(values, "DATABASE_URL"))
  use log_format <- result.try(string(values, "LOG_FORMAT"))
  use log_schema_url <- result.map(optional_string(values, "LOG_SCHEMA_URL"))
  Config(role:, database_url:, log_format:, log_schema_url:)
}

fn get(values: Dict(String, Value), name: String) -> Result(Value, String) {
  dict.get(values, name) |> result.replace_error(name <> " is not declared")
}

fn wrong(name: String, want: String) -> Result(a, String) {
  Error(name <> " is not " <> want)
}

fn string(values: Dict(String, Value), name: String) -> Result(String, String) {
  case get(values, name) {
    Ok(StringValue(s)) -> Ok(s)
    Ok(_) -> wrong(name, "a string")
    Error(e) -> Error(e)
  }
}

fn optional_string(
  values: Dict(String, Value),
  name: String,
) -> Result(Option(String), String) {
  case get(values, name) {
    Ok(StringValue(s)) -> Ok(Some(s))
    Ok(Absent) -> Ok(None)
    Ok(_) -> wrong(name, "a string")
    Error(e) -> Error(e)
  }
}

fn int(values: Dict(String, Value), name: String) -> Result(Int, String) {
  case get(values, name) {
    Ok(IntValue(i)) -> Ok(i)
    Ok(_) -> wrong(name, "an int")
    Error(e) -> Error(e)
  }
}

fn bool(values: Dict(String, Value), name: String) -> Result(Bool, String) {
  case get(values, name) {
    Ok(BoolValue(b)) -> Ok(b)
    Ok(_) -> wrong(name, "a bool")
    Error(e) -> Error(e)
  }
}

fn strings(
  values: Dict(String, Value),
  name: String,
) -> Result(List(String), String) {
  case get(values, name) {
    Ok(ListValue(items)) ->
      list.try_map(items, fn(item) {
        case item {
          StringValue(s) -> Ok(s)
          _ -> wrong(name, "a list of strings")
        }
      })
    Ok(_) -> wrong(name, "a list")
    Error(e) -> Error(e)
  }
}

// A secret string variable, or a secret text file's content. It stays a
// Secret, which prints redacted.
fn secret(
  values: Dict(String, Value),
  name: String,
) -> Result(Secret(String), String) {
  case get(values, name) {
    Ok(SecretValue(s)) ->
      case docuconf.reveal(s) {
        StringValue(_) ->
          Ok(
            docuconf.map_secret(s, fn(v) {
              let assert StringValue(text) = v
              text
            }),
          )
        _ -> wrong(name, "a secret string")
      }
    Ok(_) -> wrong(name, "secret")
    Error(e) -> Error(e)
  }
}
