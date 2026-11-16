//// Contract-first `requiredIf` (SPEC §4.2.1), `roles` (SPEC §4.9) and
//// `includes` (SPEC §4.8): the messages, role narrowing and the reader's
//// refusals, beyond what the shared suite covers.

import docuconf
import docuconf/contract_first.{Absent, IntValue, StringValue}
import docuconf/json
import gleam/dict
import gleam/list
import gleam/string
import support

fn contract(fields: String) -> json.Json {
  let assert Ok(c) =
    json.parse(
      "{\"apiVersion\": \"docuconf.dev/v1alpha1\", \"kind\": \"ConfigContract\", \"metadata\": {\"name\": \"svc\"}, "
      <> fields
      <> "}",
    )
  c
}

fn load(c: json.Json, env: List(#(String, String))) {
  contract_first.load_json(
    c,
    docuconf.options()
      |> docuconf.with_env(dict.from_list(env))
      |> docuconf.without_termination_log,
  )
}

fn violations(result) -> List(#(String, String, String)) {
  case result {
    Ok(_) -> []
    Error(docuconf.InvalidConfig(vs)) ->
      list.map(vs, fn(v: docuconf.Violation) {
        #(v.input, docuconf.code_to_string(v.code), v.message)
      })
    Error(e) -> [#("error", "", docuconf.describe(e))]
  }
}

fn codes(result) -> List(#(String, String)) {
  violations(result) |> list.map(fn(v) { #(v.0, v.1) })
}

/// The declaration problems of a contract, or none when it loads (or fails
/// on its values).
fn problems(c: json.Json) -> List(String) {
  case load(c, []) {
    Error(docuconf.InvalidDeclaration(ps)) -> ps
    _ -> []
  }
}

fn has_problem(c: json.Json, part: String) -> Bool {
  list.any(problems(c), string.contains(_, part))
}

// ---- requiredIf ------------------------------------------------------------------

const conditional = "\"vars\": {
  \"TLS_ENABLED\": {\"type\": \"bool\", \"description\": \"Serve HTTPS\", \"default\": false},
  \"TLS_CLIENT_CA_SUBJECT\": {\"type\": \"string\", \"description\": \"Client CA subject\", \"requiredIf\": {\"TLS_ENABLED\": true}},
  \"LOG_FORMAT\": {\"type\": \"enum\", \"description\": \"Log output format\", \"values\": [\"text\", \"json\"], \"default\": \"text\"},
  \"LOG_SCHEMA_URL\": {\"type\": \"url\", \"description\": \"Log schema\", \"requiredIf\": {\"LOG_FORMAT\": \"json\"}},
  \"PORT\": {\"type\": \"int\", \"description\": \"Listen port\", \"default\": 8080},
  \"ACME_EMAIL\": {\"type\": \"string\", \"description\": \"ACME contact\", \"secret\": true, \"requiredIf\": {\"PORT\": 443}}
},
\"files\": {
  \"allowlist\": {\"type\": \"text\", \"description\": \"Allowed clients\", \"path\": \"/etc/relay/allowlist/allow.txt\", \"requiredIf\": {\"TLS_ENABLED\": true}}
}"

pub fn required_if_messages_test() {
  let assert [
    #("ACME_EMAIL", "missing_required", "is required when PORT is 443"),
    #(
      "LOG_SCHEMA_URL",
      "missing_required",
      "is required when LOG_FORMAT is \"json\"",
    ),
    #(
      "TLS_CLIENT_CA_SUBJECT",
      "missing_required",
      "is required when TLS_ENABLED is true",
    ),
    #("allowlist", "file_missing", file_message),
  ] =
    violations(
      load(contract(conditional), [
        #("TLS_ENABLED", "true"),
        #("LOG_FORMAT", "json"),
        #("PORT", "443"),
      ]),
    )
  let assert True =
    string.ends_with(
      file_message,
      "/etc/relay/allowlist/allow.txt not found, and is required when TLS_ENABLED is true",
    )
}

pub fn required_if_off_leaves_inputs_optional_test() {
  let assert Ok(values) = load(contract(conditional), [])
  let assert Ok(Absent) = dict.get(values, "TLS_CLIENT_CA_SUBJECT")
  let assert Ok(Absent) = dict.get(values, "LOG_SCHEMA_URL")
  let assert Ok(Absent) = dict.get(values, "ACME_EMAIL")
  let assert Ok(Absent) = dict.get(values, "allowlist")
}

pub fn required_if_holds_and_input_is_set_test() {
  let root = support.temp_dir()
  support.write(root <> "/etc/relay/allowlist/allow.txt", "billing")
  let assert Ok(values) =
    load(contract(conditional), [
      #("DOCUCONF_FILE_ROOT", root),
      #("TLS_ENABLED", "true"),
      #("TLS_CLIENT_CA_SUBJECT", "CN=Client CA"),
    ])
  let assert Ok(StringValue("CN=Client CA")) =
    dict.get(values, "TLS_CLIENT_CA_SUBJECT")
  let assert Ok(StringValue("billing\n")) = dict.get(values, "allowlist")
  let _ = support.shell("rm -rf '" <> root <> "'")
}

pub fn required_if_on_a_default_test() {
  let c =
    contract(
      "\"vars\": {\"PORT\": {\"type\": \"int\", \"description\": \"Listen port\", \"default\": 443},"
      <> "\"ACME_EMAIL\": {\"type\": \"string\", \"description\": \"ACME contact\", \"requiredIf\": {\"PORT\": 443}}}",
    )
  let assert [#("ACME_EMAIL", "missing_required")] = codes(load(c, []))
  let assert Ok(values) = load(c, [#("PORT", "8080")])
  let assert Ok(IntValue(8080)) = dict.get(values, "PORT")
}

pub fn required_if_on_an_invalid_condition_variable_test() {
  // TLS_ENABLED has no value, so nothing is required.
  let assert [#("TLS_ENABLED", "invalid_type")] =
    codes(load(contract(conditional), [#("TLS_ENABLED", "yes")]))
}

pub fn required_if_reader_refusals_test() {
  let with = fn(input) {
    contract(
      "\"vars\": {\"FLAG\": {\"type\": \"bool\", \"description\": \"Some flag\"},"
      <> "\"SIZE\": {\"type\": \"int\", \"description\": \"Some size\", \"min\": 1, \"max\": 10},"
      <> "\"MODE\": {\"type\": \"enum\", \"description\": \"Some mode\", \"values\": [\"a\", \"b\"]},"
      <> "\"RATIO\": {\"type\": \"float\", \"description\": \"Some ratio\"},"
      <> "\"TOKEN\": {\"type\": \"string\", \"description\": \"Some token\", \"secret\": true},"
      <> "\"INPUT\": {\"type\": \"string\", \"description\": \"The input\", "
      <> input
      <> "}}",
    )
  }
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"FLAG\": true, \"SIZE\": 2}"),
      "variable INPUT: requiredIf must name one variable and its value",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"FLAG\": [true]}"),
      "requiredIf must name one variable and a string, integer or boolean value",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"FLAG\": 1.5}"),
      "requiredIf must name one variable and a string, integer or boolean value",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"NOPE\": true}"),
      "requiredIf must name another declared variable, not \"NOPE\"",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"INPUT\": \"x\"}"),
      "requiredIf must name another declared variable, not \"INPUT\"",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"TOKEN\": \"x\"}"),
      "requiredIf names TOKEN, which is not a plain string, int, bool or enum variable",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"RATIO\": 1}"),
      "requiredIf names RATIO, which is not a plain string, int, bool or enum variable",
    )
  // A bool is not an int, nor an int a bool.
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"FLAG\": 1}"),
      "requiredIf: FLAG is 1 is not a value FLAG can have",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"SIZE\": true}"),
      "requiredIf: SIZE is true is not a value SIZE can have",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"SIZE\": 20}"),
      "requiredIf: SIZE is 20 is not a value SIZE can have: default does not satisfy",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"MODE\": \"c\"}"),
      "requiredIf: MODE is \"c\" is not a value MODE can have: default does not satisfy",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"FLAG\": true}, \"required\": true"),
      "an input with requiredIf cannot be required or have a default",
    )
  let assert True =
    has_problem(
      with("\"requiredIf\": {\"FLAG\": true}, \"default\": \"x\""),
      "an input with requiredIf cannot be required or have a default",
    )
  let assert True =
    has_problem(
      with(
        "\"requiredIf\": {\"FLAG\": true}, \"deprecated\": {\"message\": \"Use something else\"}",
      ),
      "a conditionally required input cannot be deprecated",
    )
  // Every accepted form.
  let assert [] = problems(with("\"requiredIf\": {\"FLAG\": false}"))
  let assert [] = problems(with("\"requiredIf\": {\"SIZE\": 10}"))
  let assert [] = problems(with("\"requiredIf\": {\"MODE\": \"b\"}"))
}

pub fn required_if_on_a_file_is_checked_test() {
  let c =
    contract(
      "\"vars\": {}, \"files\": {\"motd\": {\"type\": \"text\", \"description\": \"Message of the day\", \"path\": \"/etc/app/motd.txt\", \"requiredIf\": {\"NOPE\": true}}}",
    )
  let assert True =
    has_problem(
      c,
      "file motd: requiredIf must name another declared variable, not \"NOPE\"",
    )
}

// ---- roles -----------------------------------------------------------------------

const roles = "\"roles\": [\"web\", \"worker\"],
\"vars\": {
  \"DOCUCONF_ROLE\": {\"type\": \"enum\", \"description\": \"The workload's role\", \"required\": true, \"values\": [\"web\", \"worker\"]},
  \"DATABASE_URL\": {\"type\": \"string\", \"description\": \"Database connection\", \"required\": true},
  \"ALLOWED_ORIGINS\": {\"type\": \"list\", \"items\": \"string\", \"description\": \"Allowed origins\", \"required\": true, \"roles\": [\"web\"]},
  \"QUEUES\": {\"type\": \"list\", \"items\": \"string\", \"description\": \"Queues to work\", \"required\": true, \"roles\": [\"worker\"]},
  \"CACHE_URL\": {\"type\": \"string\", \"description\": \"Cache for the web\", \"roles\": [\"web\"], \"requiredIf\": {\"DATABASE_URL\": \"shared\"}}
},
\"files\": {
  \"robots\": {\"type\": \"text\", \"description\": \"The robots.txt\", \"path\": \"/etc/shop/robots/robots.txt\", \"required\": true, \"roles\": [\"web\"]}
}"

pub fn roles_narrow_the_contract_test() {
  let c = contract(roles)
  // A worker needs its own inputs only.
  let assert [#("QUEUES", "missing_required")] =
    codes(load(c, [#("DOCUCONF_ROLE", "worker"), #("DATABASE_URL", "shared")]))
  let assert Ok(values) =
    load(c, [
      #("DOCUCONF_ROLE", "worker"),
      #("DATABASE_URL", "shared"),
      #("QUEUES", "mail"),
    ])
  let assert Ok(Absent) = dict.get(values, "ALLOWED_ORIGINS")
  let assert Ok(Absent) = dict.get(values, "CACHE_URL")
  let assert Ok(Absent) = dict.get(values, "robots")
  // A web workload needs the web inputs, and a condition applies in it.
  let assert [
    #("ALLOWED_ORIGINS", "missing_required"),
    #("CACHE_URL", "missing_required"),
    #("robots", "file_missing"),
  ] = codes(load(c, [#("DOCUCONF_ROLE", "web"), #("DATABASE_URL", "shared")]))
  // With no role, or an unknown one, the role is the one problem.
  let assert [#("DOCUCONF_ROLE", "missing_required")] =
    codes(load(c, [#("DATABASE_URL", "shared")]))
  let assert [#("DOCUCONF_ROLE", "not_in_enum")] =
    codes(load(c, [#("DOCUCONF_ROLE", "cron"), #("DATABASE_URL", "shared")]))
  let assert Ok(["web", "worker"]) = contract_first.roles(c)
}

pub fn roles_reader_refusals_test() {
  let role_var =
    "\"DOCUCONF_ROLE\": {\"type\": \"enum\", \"description\": \"The workload's role\", \"required\": true, \"values\": [\"web\", \"worker\"]}"
  let with = fn(top, input) {
    contract(
      top
      <> "\"vars\": {"
      <> role_var
      <> ", \"INPUT\": {\"type\": \"string\", \"description\": \"The input\""
      <> input
      <> "}}",
    )
  }
  let both = "\"roles\": [\"web\", \"worker\"], "
  let assert [] = problems(with(both, ", \"roles\": [\"web\"]"))
  let assert True =
    has_problem(
      with("\"roles\": [], ", ""),
      "roles must be a list of at least one role name",
    )
  let assert True =
    has_problem(
      with("\"roles\": [\"Web\", \"worker\"], ", ""),
      "role \"Web\" must be a DNS label",
    )
  let assert True =
    has_problem(
      with("\"roles\": [\"web\", \"worker\", \"web\"], ", ""),
      "role web is listed twice",
    )
  let assert True =
    has_problem(
      with(both, ", \"roles\": [\"cron\"]"),
      "variable INPUT: role cron is not one of the contract's roles, web, worker",
    )
  let assert True =
    has_problem(
      with(both, ", \"roles\": [\"web\", \"web\"]"),
      "variable INPUT: role web is listed twice",
    )
  let assert True =
    has_problem(
      with("", ", \"roles\": [\"web\"]"),
      "variable INPUT: has roles, but the contract declares none",
    )
  // DOCUCONF_ROLE must be a required enum of exactly the roles.
  let assert True =
    has_problem(
      with("\"roles\": [\"web\"], ", ""),
      "variable DOCUCONF_ROLE: a contract with roles declares it as a required enum whose values are the roles, web, used by every role",
    )
  let assert True =
    has_problem(
      contract(
        "\"roles\": [\"web\"], \"vars\": {\"DOCUCONF_ROLE\": {\"type\": \"enum\", \"description\": \"The workload's role\", \"required\": true, \"values\": [\"web\"], \"roles\": [\"web\"]}}",
      ),
      "variable DOCUCONF_ROLE: a contract with roles declares it",
    )
  let assert True =
    has_problem(
      contract("\"roles\": [\"web\"], \"vars\": {}"),
      "variable DOCUCONF_ROLE: a contract with roles declares it",
    )
}

// ---- includes --------------------------------------------------------------------

pub fn includes_test() {
  let assert Ok(["go-runtime@1", "otel@1"]) =
    contract_first.includes(contract(
      "\"includes\": [\"go-runtime@1\", \"otel@1\"], \"vars\": {}",
    ))
  let assert Ok([]) = contract_first.includes(contract("\"vars\": {}"))
  let assert True =
    has_problem(
      contract("\"includes\": [\"otel@0\", \"Otel@1\", \"otel\"], \"vars\": {}"),
      "includes: \"otel@0\" is not a fragment name, name@major",
    )
  let assert True =
    has_problem(
      contract("\"includes\": [\"otel@1\", \"otel@1\"], \"vars\": {}"),
      "includes: otel@1 is listed twice",
    )
  let assert True =
    has_problem(
      contract("\"includes\": \"otel@1\", \"vars\": {}"),
      "includes must be a list of fragment names, such as otel@1",
    )
}
