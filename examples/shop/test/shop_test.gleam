//// The shop's test matrix: roles, requiredIf and the otel@1 fragment, each
//// case from the base environment with a fresh, empty file root.

import docuconf
import docuconf/contract_first
import docuconf/json
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import shop
import shop/config.{type Config, Web, Worker}

pub fn main() -> Nil {
  gleeunit.main()
}

const base = [#("DATABASE_URL", "postgres://shop@db:5432/shop")]

const key_path = "/etc/shop/webhooks/signing.key"

/// Loads the contract with `env` plus the base environment, and the files in
/// `files` (path under the root, content) written to a new file root.
fn load_files(
  env: List(#(String, String)),
  files: List(#(String, String)),
) -> Result(Config, docuconf.Error) {
  let assert Ok(contract) = shop.contract()
  let root = temp_dir()
  list.each(files, fn(file) { write_file(root <> file.0, file.1) })
  let options =
    docuconf.options()
    |> docuconf.with_env(
      dict.from_list(list.flatten([base, env, [#("DOCUCONF_FILE_ROOT", root)]])),
    )
  let result = config.load(contract, options)
  remove_dir(root)
  result
}

fn load(env: List(#(String, String))) -> Result(Config, docuconf.Error) {
  load_files(env, [])
}

/// The one violation of a failed load.
fn only_violation(
  result: Result(Config, docuconf.Error),
) -> docuconf.Violation {
  let assert Error(docuconf.InvalidConfig([violation])) = result
  violation
}

// 1
pub fn web_test() {
  let assert Ok(config) =
    load([
      #("DOCUCONF_ROLE", "web"),
      #("ALLOWED_ORIGINS", "https://shop.example"),
    ])
  assert config.role
    == Web(port: 8080, allowed_origins: ["https://shop.example"])
  assert config.summary(config)
    == "shop web: port 8080, origins https://shop.example"
}

// 2: ALLOWED_ORIGINS is required for web only.
pub fn worker_test() {
  let assert Ok(config) =
    load([#("DOCUCONF_ROLE", "worker"), #("QUEUES", "default,mail")])
  assert config.role
    == Worker(queues: ["default", "mail"], webhook_signing_key: None)
  assert config.summary(config)
    == "shop worker: queues default,mail, webhooks off"
}

// 3
pub fn web_without_origins_test() {
  let violation = only_violation(load([#("DOCUCONF_ROLE", "web")]))
  assert violation.input == "ALLOWED_ORIGINS"
  assert violation.code == docuconf.MissingRequired
}

// 4: without a role, no role's inputs are required.
pub fn no_role_test() {
  let violation = only_violation(load([#("QUEUES", "default")]))
  assert violation.input == "DOCUCONF_ROLE"
  assert violation.code == docuconf.MissingRequired
}

// 5
pub fn unknown_role_test() {
  let violation = only_violation(load([#("DOCUCONF_ROLE", "cron")]))
  assert violation.input == "DOCUCONF_ROLE"
  assert violation.code == docuconf.NotInEnum
}

const json_logs = [
  #("DOCUCONF_ROLE", "worker"),
  #("QUEUES", "default"),
  #("LOG_FORMAT", "json"),
]

// 6: requiredIf on a variable.
pub fn json_logs_without_schema_test() {
  let violation = only_violation(load(json_logs))
  assert violation.input == "LOG_SCHEMA_URL"
  assert violation.code == docuconf.MissingRequired
  assert string.contains(
    violation.message,
    "is required when LOG_FORMAT is \"json\"",
  )
}

// 7
pub fn json_logs_with_schema_test() {
  let assert Ok(config) =
    load([#("LOG_SCHEMA_URL", "https://logs.example/v1.json"), ..json_logs])
  assert config.log_format == "json"
  assert config.log_schema_url == Some("https://logs.example/v1.json")
}

const webhooks = [
  #("DOCUCONF_ROLE", "worker"),
  #("QUEUES", "default"),
  #("WEBHOOKS_ENABLED", "true"),
]

// 8: requiredIf on a file.
pub fn webhooks_without_key_test() {
  let violation = only_violation(load(webhooks))
  assert violation.input == "webhook-signing-key"
  assert violation.kind == docuconf.FileKind
  assert violation.code == docuconf.FileMissing
  assert string.contains(
    violation.message,
    ", and is required when WEBHOOKS_ENABLED is true",
  )
}

// 9
pub fn webhooks_with_key_test() {
  let key = "whsec-0123456789abcdef0123456789abcdef"
  let assert Ok(config) = load_files(webhooks, [#(key_path, key)])
  let assert Worker(webhook_signing_key: Some(secret), ..) = config.role
  assert docuconf.reveal(secret) == key
  assert config.summary(config) == "shop worker: queues default, webhooks on"
}

// 10: the key file belongs to the worker role.
pub fn web_ignores_webhooks_test() {
  let assert Ok(config) =
    load([
      #("DOCUCONF_ROLE", "web"),
      #("ALLOWED_ORIGINS", "https://shop.example"),
      #("WEBHOOKS_ENABLED", "true"),
    ])
  assert config.summary(config)
    == "shop web: port 8080, origins https://shop.example"
}

// 11: the otel@1 fragment's variables are checked at boot.
pub fn bad_otel_protocol_test() {
  let violation =
    only_violation(
      load([
        #("DOCUCONF_ROLE", "web"),
        #("ALLOWED_ORIGINS", "https://shop.example"),
        #("OTEL_EXPORTER_OTLP_PROTOCOL", "carrier-pigeon"),
      ]),
    )
  assert violation.input == "OTEL_EXPORTER_OTLP_PROTOCOL"
  assert violation.code == docuconf.NotInEnum
}

// The report never prints the database URL, which is secret.
pub fn report_hides_secrets_test() {
  let assert Ok(contract) = shop.contract()
  let options =
    docuconf.options()
    |> docuconf.with_env(
      dict.from_list([
        #("DATABASE_URL", "mysql://shop:s3cret@db/shop"),
        #("DOCUCONF_ROLE", "web"),
      ]),
    )
  let assert Error(error) = config.load(contract, options)
  let report = docuconf.describe(error)
  assert string.contains(report, "DATABASE_URL [invalid_scheme]")
  assert string.contains(report, "ALLOWED_ORIGINS [missing_required]")
  assert !string.contains(report, "s3cret")
}

// The contract declares the roles and includes the fragment.
pub fn contract_test() {
  let assert Ok(contract) = shop.contract()
  let assert Ok(contract) = json.parse(contract)
  assert contract_first.roles(contract) == Ok(["web", "worker"])
  assert contract_first.includes(contract) == Ok(["otel@1"])
}

@external(erlang, "shop_test_ffi", "temp_dir")
@external(javascript, "./shop_test_ffi.mjs", "temp_dir")
fn temp_dir() -> String

@external(erlang, "shop_test_ffi", "write_file")
@external(javascript, "./shop_test_ffi.mjs", "write_file")
fn write_file(path: String, text: String) -> Nil

@external(erlang, "shop_test_ffi", "remove_dir")
@external(javascript, "./shop_test_ffi.mjs", "remove_dir")
fn remove_dir(path: String) -> Nil
