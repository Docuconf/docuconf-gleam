//// The beta features: key sets, deprecated inputs, strict parsing, YAML and
//// TOML config files, reload: watch, and contract-first profiles, overlays
//// and files beyond what the shared suite covers.

import docuconf
import docuconf/contract_first
import docuconf/json
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support

fn load(spec, env: List(#(String, String))) {
  docuconf.load_with(
    spec,
    docuconf.options()
      |> docuconf.with_env(dict.from_list(env))
      |> docuconf.without_termination_log,
  )
}

fn codes(result) -> List(#(String, String)) {
  case result {
    Ok(_) -> []
    Error(docuconf.InvalidConfig(vs)) ->
      list.map(vs, fn(v: docuconf.Violation) {
        #(v.input, docuconf.code_to_string(v.code))
      })
    Error(docuconf.InvalidDeclaration(ps)) -> [
      #("declaration", string.join(ps, "; ")),
    ]
    Error(e) -> [#("error", docuconf.describe(e))]
  }
}

fn one(var) {
  use value <- docuconf.env(var)
  use v <- docuconf.build
  value(v)
}

// ---- key sets -------------------------------------------------------------------

const old_key = "old-webhook-key-0123456789abcdef0123"

const new_key = "new-webhook-key-0123456789abcdef0123"

fn webhook_keys() {
  docuconf.key_set("WEBHOOK_KEYS", "Keys that verify webhook signatures")
  |> docuconf.key_min_length(32)
  |> docuconf.key_max_length(256)
}

pub fn key_set_loads_keys_in_order_test() {
  let assert Ok(set) =
    load(one(docuconf.required(webhook_keys())), [
      #("WEBHOOK_KEYS", old_key <> "," <> new_key),
    ])
  let assert [a, b] = docuconf.keys(set)
  let assert True = a == old_key && b == new_key
  let assert True = docuconf.contains(set, new_key)
  let assert False = docuconf.contains(set, "new-webhook-key")
  let assert False = docuconf.contains(set, "")
  let tried = docuconf.any_key(set, fn(k) { k == old_key })
  let assert True = tried
  let assert False = docuconf.any_key(set, fn(_) { False })
}

pub fn any_key_tries_every_key_test() {
  let assert Ok(set) =
    load(one(docuconf.required(webhook_keys())), [
      #("WEBHOOK_KEYS", old_key <> "," <> new_key),
    ])
  let _ = support.recall()
  let assert True =
    docuconf.any_key(set, fn(k) {
      support.remember(string.slice(k, 0, 3))
      True
    })
  // Both keys were checked, though the first matched.
  let assert ["old", "new"] = support.recall()
}

pub fn key_set_is_redacted_test() {
  let assert Ok(set) =
    load(one(docuconf.required(webhook_keys())), [#("WEBHOOK_KEYS", old_key)])
  let assert False = string.contains(string.inspect(set), "webhook-key")
  let assert False =
    string.contains(string.inspect(Some(#(1, set))), "webhook-key")
}

pub fn key_set_errors_test() {
  let spec = one(docuconf.required(webhook_keys()))
  let check = fn(value, code) {
    let result = load(spec, [#("WEBHOOK_KEYS", value)])
    let assert [#("WEBHOOK_KEYS", c)] = codes(result)
    let assert True = c == code
    let assert Error(e) = result
    // No message holds a key, or any part of one.
    let assert False = string.contains(docuconf.describe(e), "webhook-key")
  }
  check(old_key <> ",", "out_of_range")
  check(old_key <> ",new-webhook-key", "out_of_range")
  check(old_key <> "," <> new_key <> "," <> old_key, "too_many_items")
  check(string.repeat("k", 257), "out_of_range")
  let assert [#("WEBHOOK_KEYS", "missing_required")] = codes(load(spec, []))
  // An empty key is out of range even without key_min_length.
  let bare =
    one(
      docuconf.key_set_with(
        "API_KEYS",
        "Keys callers present",
        encoding: docuconf.JsonArray,
      )
      |> docuconf.optional,
    )
  let assert [#("API_KEYS", "out_of_range")] =
    codes(load(bare, [#("API_KEYS", "[\"a\",\"\"]")]))
  let assert [#("API_KEYS", "too_few_items")] =
    codes(load(bare, [#("API_KEYS", "[]")]))
  let assert [#("API_KEYS", "invalid_type")] =
    codes(load(bare, [#("API_KEYS", "{\"k\": \"a\"}")]))
  let assert Ok(None) = load(bare, [])
}

pub fn key_set_limits_replace_the_defaults_test() {
  let spec =
    one(
      docuconf.key_set("KEYS", "Keys that callers present")
      |> docuconf.min_keys(2)
      |> docuconf.max_keys(3)
      |> docuconf.required,
    )
  let assert [#("KEYS", "too_few_items")] = codes(load(spec, [#("KEYS", "a")]))
  let assert Ok(_) = load(spec, [#("KEYS", "a,b,c")])
  let assert [#("KEYS", "too_many_items")] =
    codes(load(spec, [#("KEYS", "a,b,c,d")]))
}

pub fn key_set_export_and_declaration_test() {
  let assert Ok(cue) =
    docuconf.contract(one(docuconf.required(webhook_keys())), name: "svc")
  let assert True = string.contains(cue, "type: \"keySet\"")
  let assert True = string.contains(cue, "secret: true")
  let assert True = string.contains(cue, "minKeys: 1")
  let assert True = string.contains(cue, "maxKeys: 2")
  let assert True = string.contains(cue, "keyMinLength: 32")
  let assert True = string.contains(cue, "keyMaxLength: 256")
  let assert False = string.contains(cue, "items:")
  let bad =
    one(
      docuconf.key_set("KEYS", "Keys that callers present")
      |> docuconf.min_keys(0)
      |> docuconf.key_min_length(10)
      |> docuconf.key_max_length(5)
      |> docuconf.optional,
    )
  let problems = docuconf.check_declaration(bad)
  let assert True =
    list.any(problems, string.contains(_, "min_keys must be at least 1"))
  let assert True =
    list.any(problems, string.contains(
      _,
      "key_min_length 10 is greater than key_max_length 5",
    ))
}

// ---- deprecated -----------------------------------------------------------------

fn problems(var) {
  docuconf.check_declaration(one(var))
}

pub fn deprecated_rules_test() {
  let assert [p] =
    problems(
      docuconf.int("OLD_PORT", "Old listen port")
      |> docuconf.deprecated("  ")
      |> docuconf.optional,
    )
  let assert True = string.contains(p, "must say what to use instead")
  let assert [p] =
    problems(
      docuconf.int("OLD_PORT", "Old listen port")
      |> docuconf.deprecated(string.repeat("x", 501))
      |> docuconf.optional,
    )
  let assert True = string.contains(p, "at most 500")
  let assert [] =
    problems(
      docuconf.int("OLD_PORT", "Old listen port")
      |> docuconf.deprecated(string.repeat("x", 500))
      |> docuconf.optional,
    )
  let assert [p] =
    problems(
      docuconf.int("OLD_PORT", "Old listen port")
      |> docuconf.deprecated("Use PORT instead")
      |> docuconf.required,
    )
  let assert True = string.contains(p, "a required input cannot be deprecated")
  let assert [p] =
    problems(
      docuconf.int("OLD_PORT", "Old listen port")
      |> docuconf.replaced_by("PORT")
      |> docuconf.optional,
    )
  let assert True = string.contains(p, "replaced_by needs deprecated")
}

pub fn deprecated_warning_names_the_input_never_the_value_test() {
  let spec =
    one(
      docuconf.string("OLD_TOKEN", "Token of the retired API")
      |> docuconf.deprecated("The billing API no longer takes a token")
      |> docuconf.replaced_by("BILLING_KEY")
      |> docuconf.secret
      |> docuconf.optional,
    )
  let _ = support.recall()
  let assert Ok(Some(_)) =
    docuconf.load_with(
      spec,
      docuconf.options()
        |> docuconf.with_env(dict.from_list([#("OLD_TOKEN", "tok-0123456789")]))
        |> docuconf.without_termination_log
        |> docuconf.on_warning(support.remember),
    )
  let assert [w] = support.recall()
  let assert True =
    w
    == "OLD_TOKEN is deprecated: The billing API no longer takes a token (replaced by BILLING_KEY)"
  // Unset: no warning.
  let assert Ok(None) =
    docuconf.load_with(
      spec,
      docuconf.options()
        |> docuconf.with_env(dict.new())
        |> docuconf.on_warning(support.remember),
    )
  let assert [] = support.recall()
}

pub fn deprecated_export_test() {
  let assert Ok(cue) =
    docuconf.contract(
      one(
        docuconf.int("OLD_PORT", "Old listen port")
        |> docuconf.deprecated("Use PORT instead")
        |> docuconf.replaced_by("PORT")
        |> docuconf.optional,
      ),
      name: "svc",
    )
  let assert True =
    string.contains(
      cue,
      "deprecated: {\n\t\t\t\tmessage: \"Use PORT instead\"\n\t\t\t\treplacedBy: \"PORT\"\n\t\t\t}",
    )
}

// ---- strict parsing -------------------------------------------------------------

fn parses(b, value) {
  load(one(docuconf.optional(b)), [#("V", value)])
}

pub fn strict_parsing_test() {
  let flag = docuconf.bool("V", "A switch to test")
  let assert Ok(Some(True)) = parses(flag, "TRUE")
  let assert Ok(Some(False)) = parses(flag, "fAlSe")
  list.each(["1", "0", "t", "yes", "on", " true", "true\n"], fn(bad) {
    let assert [#("V", "invalid_type")] = codes(parses(flag, bad))
  })
  let n = docuconf.int("V", "A number to test")
  let assert Ok(Some(7)) = parses(n, "007")
  let assert Ok(Some(5)) = parses(n, "+5")
  list.each(["0x10", "1_000", "1e3", "5.0", " 5", "-", "+-5", "١٢"], fn(bad) {
    let assert [#("V", "invalid_type")] = codes(parses(n, bad))
  })
  let f = docuconf.float("V", "A ratio to test")
  let assert Ok(Some(1000.0)) = parses(f, "1E3")
  let assert Ok(Some(7.5)) = parses(f, "007.5")
  list.each(
    [".5", "5.", "inf", "NaN", "0x1p4", "1e", "1e400", "1_0.5"],
    fn(bad) {
      let assert [#("V", "invalid_type")] = codes(parses(f, bad))
    },
  )
  let names = docuconf.string_list("V", "Names to test", separator: ",")
  let assert Ok(Some(["a", " b ", "", "c"])) = parses(names, "a, b ,,c")
}

// ---- YAML and TOML config files -----------------------------------------------

pub fn yaml_and_toml_config_files_test() {
  let root = support.temp_dir()
  support.write(
    root <> "/etc/app/a/settings.yaml",
    "name: orders # the service\ntags: [a, b]\nlimits:\n  burst: 10\nlist:\n- x\n- y: 1\n",
  )
  support.write(
    root <> "/etc/app/b/settings.toml",
    "name = \"orders\"\ntags = [\"a\", \"b\"]\n[limits]\nburst = 10\n",
  )
  let spec = {
    use y <- docuconf.file(
      docuconf.config_file_with(
        "settings-yaml",
        "Settings as YAML",
        path: "/etc/app/a/settings.yaml",
        format: "yaml",
        parse: docuconf.parse_yaml,
        decoder: json.decoder(),
      )
      |> docuconf.file_required,
    )
    use t <- docuconf.file(
      docuconf.config_file_with(
        "settings-toml",
        "Settings as TOML",
        path: "/etc/app/b/settings.toml",
        format: "toml",
        parse: docuconf.parse_toml,
        decoder: json.decoder(),
      )
      |> docuconf.file_required,
    )
    use v <- docuconf.build
    #(y(v), t(v))
  }
  let opts =
    docuconf.options()
    |> docuconf.with_env(dict.new())
    |> docuconf.with_file_root(root)
  let assert Ok(#(y, t)) = docuconf.load_with(spec, opts)
  let assert "{\"limits\":{\"burst\":10},\"list\":[\"x\",{\"y\":1}],\"name\":\"orders\",\"tags\":[\"a\",\"b\"]}" =
    json.to_string(y)
  let assert "{\"limits\":{\"burst\":10},\"name\":\"orders\",\"tags\":[\"a\",\"b\"]}" =
    json.to_string(t)
  // Anchors are reported, not misread.
  support.write(root <> "/etc/app/a/settings.yaml", "a: &x 1\nb: *x\n")
  let assert [#("settings-yaml", "file_malformed")] =
    codes(docuconf.load_with(spec, opts))
  let _ = support.shell("rm -rf '" <> root <> "'")
}

// ---- reload: watch ----------------------------------------------------------------

pub fn reload_watch_test() {
  let root = support.temp_dir()
  let path = "/etc/app/motd/motd.txt"
  support.write(root <> path, "hello")
  let spec = {
    use motd <- docuconf.file(
      docuconf.text("motd", "Message of the day", path:)
      |> docuconf.text_max_length(10)
      |> docuconf.reload_watch
      |> docuconf.file_required,
    )
    use v <- docuconf.build
    motd(v)
  }
  let assert Ok(cue) = docuconf.contract(spec, name: "svc")
  let assert True = string.contains(cue, "reload: \"watch\"")
  let assert Ok(motd) =
    docuconf.load_with(
      spec,
      docuconf.options()
        |> docuconf.with_env(dict.new())
        |> docuconf.with_file_root(root),
    )
  // support.write ends the file with a newline.
  let assert "hello\n" = docuconf.current(motd)
  // A change is read at most once a second.
  support.write(root <> path, "bonjour")
  let _ = support.sh("sleep 1.2")
  let assert "bonjour\n" = docuconf.current(motd)
  // A change that fails its checks keeps the previous content.
  support.write(root <> path, "a message far too long")
  let _ = support.sh("sleep 1.2")
  let assert "bonjour\n" = docuconf.current(motd)
  let _ = support.shell("rm -rf '" <> root <> "'")
}

// ---- contract-first -------------------------------------------------------------

fn contract(fields: String) -> json.Json {
  let assert Ok(c) =
    json.parse(
      "{\"apiVersion\": \"docuconf.dev/v1alpha1\", \"kind\": \"ConfigContract\", \"metadata\": {\"name\": \"svc\"}, "
      <> fields
      <> "}",
    )
  c
}

fn cf_load(c: json.Json, env: List(#(String, String))) {
  contract_first.load_json(
    c,
    docuconf.options()
      |> docuconf.with_env(dict.from_list(env))
      |> docuconf.without_termination_log,
  )
}

pub fn contract_first_watch_is_rejected_test() {
  let c =
    contract(
      "\"vars\": {}, \"files\": {\"motd\": {\"type\": \"text\", \"description\": \"Message of the day\", \"path\": \"/etc/app/motd.txt\", \"reload\": \"watch\"}}",
    )
  let assert Error(docuconf.InvalidDeclaration([p])) = cf_load(c, [])
  let assert True = string.contains(p, "reload: watch is not supported")
}

pub fn contract_first_overlay_secret_and_env_test() {
  let root = support.temp_dir()
  support.write(
    root <> "/app/config/platform.json",
    "{\"Db\": {\"Password\": \"hunter2-overlay\", \"Pool\": 5}}",
  )
  let c =
    contract(
      "\"vars\": {\"DB__PASSWORD\": {\"type\": \"string\", \"description\": \"Database password\", \"secret\": true, \"configKey\": \"Db:Password\"},"
      <> "\"DB__POOL\": {\"type\": \"int\", \"description\": \"Connection pool size\", \"configKey\": \"Db:Pool\", \"default\": 2}},"
      <> "\"overlays\": {\"platform\": {\"format\": \"json\", \"path\": \"/app/config/platform.json\", \"keySeparator\": \":\"}}",
    )
  // A secret is never taken from an overlay, and never printed.
  let result = cf_load(c, [#("DOCUCONF_FILE_ROOT", root)])
  let assert [#("DB__PASSWORD", "invalid_type")] = codes(result)
  let assert Error(e) = result
  let assert False = string.contains(docuconf.describe(e), "hunter2")
  // The environment beats the overlay; the overlay beats the default.
  support.write(root <> "/app/config/platform.json", "{\"Db\": {\"Pool\": 5}}")
  let pool = fn(env) {
    let assert Ok(values) = cf_load(c, [#("DOCUCONF_FILE_ROOT", root), ..env])
    dict.get(values, "DB__POOL")
  }
  let assert Ok(contract_first.IntValue(5)) = pool([])
  let assert Ok(contract_first.IntValue(9)) = pool([#("DB__POOL", "9")])
  let _ = support.shell("rm -rf '" <> root <> "'")
}

pub fn contract_first_profile_declaration_test() {
  let c =
    contract(
      "\"vars\": {\"APP_ENV\": {\"type\": \"string\", \"description\": \"Which profile loads\", \"default\": \"Production\"},"
      <> "\"PAGE_SIZE\": {\"type\": \"int\", \"description\": \"Items per page\", \"max\": 100}},"
      <> "\"profiles\": {\"selector\": \"APP_ENV\", \"default\": \"Production\", \"defaults\": {\"Production\": {\"PAGE_SIZE\": 500, \"NOPE\": 1}}}",
    )
  let assert Error(docuconf.InvalidDeclaration(problems)) = cf_load(c, [])
  let assert True =
    list.any(problems, string.contains(_, "NOPE is not a declared variable"))
  let assert True =
    list.any(problems, string.contains(
      _,
      "profiles.defaults.Production: PAGE_SIZE",
    ))
}
