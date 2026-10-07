//// Regressions for the developer-experience review: the declaration is
//// read without running app code, values are read through handles,
//// secrets are redacted, and the helpers for boot, export and tests.

import docuconf
import docuconf/contract_first
import docuconf/duration
import docuconf/json
import envoy
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import support

fn opts(env: List(#(String, String))) -> docuconf.Options {
  docuconf.options()
  |> docuconf.with_env(dict.from_list(env))
}

fn messages(result: Result(a, docuconf.Error)) -> List(String) {
  case result {
    Error(docuconf.InvalidConfig(vs)) ->
      list.map(vs, fn(v: docuconf.Violation) {
        v.input <> " [" <> docuconf.code_to_string(v.code) <> "]: " <> v.message
      })
    Error(e) -> [docuconf.describe(e)]
    Ok(_) -> []
  }
}

// ---- no placeholder values --------------------------------------------------

fn host_spec() -> docuconf.Spec(String) {
  use host <- docuconf.env(
    docuconf.url("DATABASE_URL", "Postgres connection string")
    |> docuconf.required
    |> docuconf.map(fn(s) {
      // Code that assumes a real value: it crashed on the "" placeholder.
      let assert Ok(u) = uri.parse(s)
      let assert Some(h) = u.host
      h
    }),
  )
  use v <- docuconf.build
  host(v)
}

pub fn map_runs_only_on_real_values_test() {
  let assert Ok("db.internal") =
    docuconf.load_with(
      host_spec(),
      opts([#("DATABASE_URL", "postgres://u:p@db.internal/x")]),
    )
  // Export and declaration checks run none of the app's code.
  let assert Ok(_) = docuconf.contract(host_spec(), name: "svc")
  let assert [] = docuconf.check_declaration(host_spec())
  // A missing value is reported; map never sees it.
  let assert ["DATABASE_URL [missing_required]: required, but not set"] =
    messages(docuconf.load_with(host_spec(), opts([])))
}

pub fn build_runs_only_after_every_input_passed_test() {
  let spec = {
    use port <- docuconf.env(
      docuconf.int("PORT", "HTTP listen port") |> docuconf.required,
    )
    use v <- docuconf.build
    case port(v) {
      0 -> panic as "build ran on a placeholder"
      n -> n
    }
  }
  let assert Ok(_) = docuconf.contract(spec, name: "svc")
  let assert [] = docuconf.flag_warnings(spec)
  let assert [_] = messages(docuconf.load_with(spec, opts([])))
  let assert Ok(8080) = docuconf.load_with(spec, opts([#("PORT", "8080")]))
}

pub fn try_map_reports_a_violation_test() {
  let spec = {
    use host <- docuconf.env(
      docuconf.url("DATABASE_URL", "Postgres connection string")
      |> docuconf.required
      |> docuconf.try_map(fn(s) {
        uri.parse(s)
        |> result.try(fn(u) {
          case u.host {
            Some(h) if h != "" -> Ok(h)
            _ -> Error(Nil)
          }
        })
        |> result.replace_error("has no host")
      }),
    )
    docuconf.build(host)
  }
  let assert Ok("db") =
    docuconf.load_with(spec, opts([#("DATABASE_URL", "postgres://db/x")]))
  let assert ["DATABASE_URL [invalid_type]: \"file:///x\" has no host"] =
    messages(docuconf.load_with(spec, opts([#("DATABASE_URL", "file:///x")])))
}

// The pattern a conditional declaration needs: declare both variables
// unconditionally, then decide in build. Both are in the contract.
pub fn every_variable_is_exported_test() {
  let spec = {
    use cache_enabled <- docuconf.env(
      docuconf.bool("CACHE_ENABLED", "Use the Redis cache")
      |> docuconf.default(False),
    )
    use redis_url <- docuconf.env(
      docuconf.url("REDIS_URL", "Redis connection string") |> docuconf.optional,
    )
    use v <- docuconf.build
    case cache_enabled(v) {
      True -> redis_url(v)
      False -> None
    }
  }
  let assert Ok(cue) = docuconf.contract(spec, name: "svc")
  let assert True = string.contains(cue, "CACHE_ENABLED")
  let assert True = string.contains(cue, "REDIS_URL")
  let assert Ok(Some("redis://r")) =
    docuconf.load_with(
      spec,
      opts([#("CACHE_ENABLED", "true"), #("REDIS_URL", "redis://r")]),
    )
}

pub fn include_and_map_spec_test() {
  let db = {
    use url <- docuconf.env(
      docuconf.url("DATABASE_URL", "Postgres connection string")
      |> docuconf.required,
    )
    docuconf.build(url)
  }
  let spec = {
    use port <- docuconf.env(
      docuconf.int("PORT", "HTTP listen port") |> docuconf.default(8080),
    )
    use db <- docuconf.include(db |> docuconf.map_spec(string.length))
    use v <- docuconf.build
    #(port(v), db(v))
  }
  let assert Ok(#(8080, 8)) =
    docuconf.load_with(spec, opts([#("DATABASE_URL", "pg://h/d")]))
  let assert Ok(cue) = docuconf.contract(spec, name: "svc")
  let assert True = string.contains(cue, "DATABASE_URL")
}

// ---- secrets -------------------------------------------------------------------

fn secret_spec() {
  use url <- docuconf.env(
    docuconf.url("DATABASE_URL", "Postgres connection string")
    |> docuconf.secret
    |> docuconf.required,
  )
  docuconf.build(url)
}

pub fn secret_is_redacted_when_printed_test() {
  let assert Ok(secret) =
    docuconf.load_with(
      secret_spec(),
      opts([#("DATABASE_URL", "postgres://u:hunter2@h/db")]),
    )
  let assert "postgres://u:hunter2@h/db" = docuconf.reveal(secret)
  let printed = string.inspect(secret)
  let assert False = string.contains(printed, "hunter2")
  let assert True = string.starts_with(printed, "Secret(")
  let assert False =
    string.contains(string.inspect(#(1, Some(secret))), "hunter2")
  let assert 25 =
    docuconf.map_secret(secret, string.length)
    |> docuconf.reveal
}

pub fn secret_file_is_redacted_test() {
  let root = support.temp_dir()
  support.write(root <> "/etc/svc/key/license.key", "LICENCE-hunter2")
  let spec = {
    use key <- docuconf.file(
      docuconf.text("license", "Licence key", path: "/etc/svc/key/license.key")
      |> docuconf.secret_file
      |> docuconf.file_required,
    )
    docuconf.build(key)
  }
  let assert Ok(key) =
    docuconf.load_with(spec, opts([]) |> docuconf.with_file_root(root))
  let assert False = string.contains(string.inspect(key), "hunter2")
  let assert "LICENCE-hunter2\n" = docuconf.reveal(key)
}

pub fn secret_never_in_validator_errors_test() {
  let spec = {
    use url <- docuconf.env(
      docuconf.url("DATABASE_URL", "Postgres connection string")
      |> docuconf.secret
      |> docuconf.required
      |> docuconf.try_map(fn(s) {
        // A careless message that quotes the value.
        Error("host of " <> docuconf.reveal(s) <> " is not allowed")
      }),
    )
    docuconf.build(url)
  }
  let assert [message] =
    messages(docuconf.load_with(
      spec,
      opts([#("DATABASE_URL", "postgres://u:hunter2@h/db")]),
    ))
  let assert False = string.contains(message, "hunter2")
  let assert True = string.contains(message, "withheld")
  // A message with no part of the value is shown.
  let plain = {
    use url <- docuconf.env(
      docuconf.url("DATABASE_URL", "Postgres connection string")
      |> docuconf.secret
      |> docuconf.required
      |> docuconf.try_map(fn(_) { Error("is not on the allow list") }),
    )
    docuconf.build(url)
  }
  let assert ["DATABASE_URL [invalid_type]: is not on the allow list"] =
    messages(docuconf.load_with(
      plain,
      opts([#("DATABASE_URL", "postgres://u:hunter2@h/db")]),
    ))
}

pub fn contract_first_secret_is_redacted_test() {
  let contract =
    "{\"vars\": {\"TOKEN\": {\"type\": \"string\", \"description\": \"API token\", \"secret\": true, \"required\": true}}}"
  let assert Ok(values) =
    contract_first.load(contract, opts([#("TOKEN", "tok-hunter2")]))
  let assert Ok(value) = dict.get(values, "TOKEN")
  let assert False = string.contains(string.inspect(value), "hunter2")
  let assert True =
    string.contains(
      contract_first.to_json(value) |> json.to_string,
      "tok-hunter2",
    )
}

// ---- declarations ----------------------------------------------------------------

pub type Level {
  Debug
  Info
  Warn
}

pub fn enum_default_must_be_a_value_test() {
  let spec = {
    use level <- docuconf.env(
      docuconf.enum("LOG_LEVEL", "Minimum log level", [
        #("debug", Debug),
        #("info", Info),
      ])
      |> docuconf.default(Warn),
    )
    docuconf.build(level)
  }
  let assert [problem] = docuconf.check_declaration(spec)
  let assert True = string.starts_with(problem, "variable LOG_LEVEL: default")
  let assert True = string.contains(problem, "is not one of debug, info")
  let assert Error(docuconf.InvalidDeclaration(_)) =
    docuconf.contract(spec, name: "svc")
  let empty = {
    use level <- docuconf.env(
      docuconf.enum("LOG_LEVEL", "Minimum log level", [])
      |> docuconf.optional,
    )
    docuconf.build(level)
  }
  let assert ["variable LOG_LEVEL: values must not be empty"] =
    docuconf.check_declaration(empty)
  let assert Ok("info") =
    docuconf.enum_name([#("debug", Debug), #("info", Info)], Info)
}

pub fn typed_duration_bounds_test() {
  let spec = {
    use t <- docuconf.env(
      docuconf.duration("TIMEOUT", "Request timeout")
      |> docuconf.min_duration(duration.seconds(1))
      |> docuconf.max_duration(duration.minutes(5))
      |> docuconf.default(duration.seconds(30)),
    )
    docuconf.build(t)
  }
  let assert Ok(cue) = docuconf.contract(spec, name: "svc")
  let assert True = string.contains(cue, "max:")
  let assert True = string.contains(cue, "\"5m\"")
  let assert 7_200_000 = duration.to_milliseconds(duration.hours(2))
  let assert [_] =
    messages(docuconf.load_with(spec, opts([#("TIMEOUT", "6m")])))
}

// Rule 7: a Go-style value for an ISO 8601 duration says what is expected.
pub fn go_style_duration_hint_test() {
  let spec = {
    use t <- docuconf.env(
      docuconf.duration_with(
        "TIMEOUT",
        "Request timeout",
        encoding: docuconf.Iso8601,
      )
      |> docuconf.required,
    )
    docuconf.build(t)
  }
  let assert [message] =
    messages(docuconf.load_with(spec, opts([#("TIMEOUT", "30s")])))
  let assert True =
    string.contains(message, "is not an ISO 8601 duration such as PT30S")
  let assert True = string.contains(message, "looks like a Go duration")
}

// ---- export ---------------------------------------------------------------------

pub fn write_contract_reports_failures_test() {
  let assert Error(docuconf.WriteFailed(path: _, reason: "enoent") as e) =
    docuconf.write_contract(
      host_spec(),
      name: "svc",
      to: "/nonexistent-docuconf-dir/contract.cue",
    )
  let assert True =
    string.contains(docuconf.describe(e), "does the directory exist?")
  let dir = support.temp_dir()
  let assert Ok(Nil) =
    docuconf.write_contract(host_spec(), name: "svc", to: dir <> "/c.cue")
}

pub fn check_contract_test() {
  let dir = support.temp_dir()
  let path = dir <> "/contract.cue"
  let assert Error(missing) =
    docuconf.check_contract(host_spec(), name: "svc", against: path)
  let assert True = string.contains(missing, "cannot read")
  let assert Ok(Nil) =
    docuconf.write_contract(host_spec(), name: "svc", to: path)
  let assert Ok(Nil) =
    docuconf.check_contract(host_spec(), name: "svc", against: path)
  let assert Error(diff) =
    docuconf.check_contract(secret_spec(), name: "svc", against: path)
  let assert True = string.contains(diff, "+\t\t\tsecret: true")
}

// ---- loading ---------------------------------------------------------------------

pub fn warnings_go_to_on_warning_test() {
  let spec = {
    use url <- docuconf.env(
      docuconf.url("DATABASE_URL", "Postgres connection string")
      |> docuconf.secret
      |> docuconf.optional,
    )
    use origins <- docuconf.env(
      docuconf.string_list("ALLOWED_ORIGINS", "CORS origins", separator: ",")
      |> docuconf.optional,
    )
    use v <- docuconf.build
    #(url(v), origins(v))
  }
  let env = [
    #("DATABSE_URL", "postgres://h/db"),
    #("ALLOWED_ORIGINS", "http://a, http://b"),
  ]
  let assert Ok(_) =
    docuconf.load_with(spec, opts(env) |> docuconf.on_warning(support.remember))
  let assert [
    "ALLOWED_ORIGINS: item 2 has spaces around it; list items are not trimmed",
    "DATABSE_URL is set but not declared; did you mean DATABASE_URL?",
  ] = support.recall()
  // The same list, without loading; values never appear.
  let warnings = docuconf.warnings(spec, opts(env))
  let assert 2 = list.length(warnings)
  let assert False = string.contains(string.join(warnings, ""), "postgres")
  // with_env alone keeps the test output quiet.
  let assert Ok(_) = docuconf.load_with(spec, opts(env))
}

pub fn missing_required_names_the_typo_test() {
  let assert [
    "DATABASE_URL [missing_required]: required, but not set (DATABSE_URL is set: a typo?)",
  ] =
    messages(docuconf.load_with(
      host_spec(),
      opts([#("DATABSE_URL", "postgres://h")]),
    ))
}

pub fn trailing_newline_hint_test() {
  let assert [message] =
    messages(docuconf.load_with(
      secret_spec(),
      opts([#("DATABASE_URL", "postgres://u:p@h/db\n")]),
    ))
  let assert "DATABASE_URL [invalid_type]: is not a URL with a scheme:// (the value ends with a newline)" =
    message
}

pub fn with_env_never_reads_the_process_environment_test() {
  let dir = support.temp_dir()
  let log = dir <> "/termination-log"
  envoy.set("DOCUCONF_TERMINATION_LOG", log)
  let result = docuconf.load_with(host_spec(), opts([]))
  envoy.unset("DOCUCONF_TERMINATION_LOG")
  let assert Error(_) = result
  let assert Error(Nil) = support.read_file(log)
  // An explicit log is still written.
  let assert Error(_) =
    docuconf.load_with(
      host_spec(),
      opts([]) |> docuconf.with_termination_log(log),
    )
  let assert Ok(written) = support.read_file(log)
  let assert True = string.contains(written, "DATABASE_URL [missing_required]")
}

// Kubernetes reads at most 4096 bytes: the log is cut by bytes, on a
// character boundary.
pub fn termination_log_is_cut_by_bytes_test() {
  let dir = support.temp_dir()
  let log = dir <> "/termination-log"
  let spec = {
    use s <- docuconf.env(
      docuconf.string("NAME", "A long name")
      |> docuconf.max_length(1)
      |> docuconf.required,
    )
    docuconf.build(s)
  }
  let value = string.repeat("é", 3000)
  let assert Error(_) =
    docuconf.load_with(
      spec,
      opts([#("NAME", value)]) |> docuconf.with_termination_log(log),
    )
  let assert Ok(written) = support.read_file(log)
  let assert True = string.byte_size(written) <= 4000
  let assert True = string.byte_size(written) > 3990
}
