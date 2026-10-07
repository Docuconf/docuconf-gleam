import docuconf
import docuconf/contract_first
import docuconf/duration
import docuconf/internal/cue as cue_writer
import docuconf/json
import envoy
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import sample
import support

pub fn main() -> Nil {
  gleeunit.main()
}

// ---- helpers ------------------------------------------------------------------

fn base_env() -> List(#(String, String)) {
  [
    #("DATABASE_URL", "postgres://db/gw"),
    #("PUBLIC_URL", "https://gw.example.com"),
    #("ALLOWED_ORIGINS", "https://a.example.com"),
    #("REGION", "eu-west-1"),
  ]
}

/// A file root holding valid files for the sample spec.
fn file_root() -> String {
  let root = support.temp_dir()
  support.write(
    root <> "/etc/gateway/routes/routes.json",
    "{\"routes\": [{\"match\": \"/api\", \"upstream\": \"https://api.internal\", \"timeout\": \"5s\"}]}",
  )
  support.write(
    root <> "/etc/gateway/license/license.key",
    "ABCDE-12345-FGHIJ-67890",
  )
  let ca = root <> "/pki"
  let _ = support.sh("mkdir -p " <> ca)
  support.make_ca(ca)
  support.make_leaf(
    ca,
    root <> "/etc/gateway/tls",
    "gateway.internal,api.example.com",
    90,
    "ec",
  )
  root
}

fn load(root: String, extra: List(#(String, String))) {
  load_at(root, extra, None)
}

fn load_at(root: String, extra: List(#(String, String)), now) {
  let env = dict.from_list(list.append(base_env(), extra))
  let opts =
    docuconf.options()
    |> docuconf.with_env(env)
    |> docuconf.with_file_root(root)
    |> docuconf.without_termination_log
  let opts = case now {
    Some(t) -> docuconf.at_time(opts, t)
    None -> opts
  }
  docuconf.load_with(sample.spec(), opts)
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
  }
}

fn now() -> Int {
  let assert Ok(n) = int.parse(string.trim(support.sh("date +%s")))
  n
}

// ---- durations ------------------------------------------------------------------

pub fn duration_parse_test() {
  let ms = fn(s) {
    case duration.parse(s) {
      Ok(d) -> Ok(duration.to_milliseconds(d))
      Error(Nil) -> Error(Nil)
    }
  }
  let assert Ok(90_000) = ms("1m30s")
  let assert Ok(5_400_000) = ms("1.5h")
  let assert Ok(500) = ms(".5s")
  let assert Ok(0) = ms("0")
  list.each(["", "1", "s", "1x", "1h 2m", "PT90S", " 1s"], fn(bad) {
    let assert Error(Nil) = duration.parse(bad)
  })
}

pub fn duration_canonical_test() {
  let canon = fn(s) {
    let assert Ok(d) = duration.parse(s)
    duration.to_string(d)
  }
  let assert "1h30m" = canon("90m")
  let assert "1h30m" = canon("1.5h")
  let assert "1s500ms" = canon("1500ms")
  let assert "0s" = canon("0")
}

// SPEC §5: the iso8601, seconds and timespan wire encodings.
pub fn duration_encodings_test() {
  let canon = fn(parse: fn(String) -> Result(duration.Duration, Nil), s) {
    case parse(s) {
      Ok(d) -> Ok(duration.to_string(d))
      Error(Nil) -> Error(Nil)
    }
  }
  let iso = canon(duration.parse_iso8601, _)
  let assert Ok("1m30s") = iso("PT90S")
  let assert Ok("1s500ms") = iso("PT1.5S")
  let assert Ok("1s500ms") = iso("PT1,5S")
  let assert Ok("26h") = iso("P1DT2H")
  let assert Ok("24h") = iso("P1D")
  let assert Ok("1h30m") = iso("PT1H30M")
  let assert Ok("0s") = iso("PT0S")
  list.each(
    ["", "P", "PT", "P1DT", "PT1M2H", "PT1S1S", "P1Y", "P1W", "1m30s", "PT.5S"],
    fn(bad) {
      let assert Error(Nil) = duration.parse_iso8601(bad)
    },
  )
  let secs = canon(duration.parse_seconds, _)
  let assert Ok("1m30s") = secs("90")
  let assert Ok("250ms") = secs("0.25")
  let assert Ok("0s") = secs("0")
  list.each(["", "90s", "-1", ".5", "1.", "1e3", " 1"], fn(bad) {
    let assert Error(Nil) = duration.parse_seconds(bad)
  })
  let span = canon(duration.parse_timespan, _)
  let assert Ok("1m30s") = span("00:01:30")
  let assert Ok("26h3m4s500ms") = span("1.02:03:04.5")
  let assert Ok("2h") = span("2:00:00")
  let assert Ok("1s1ms") = span("00:00:01.0010000")
  list.each(
    [
      "",
      "1m30s",
      "24:00:00",
      "00:60:00",
      "00:00:60",
      "0:1:30",
      "00:01:30.",
      ".01:00:00",
      "00:00:00.12345678",
    ],
    fn(bad) {
      let assert Error(Nil) = duration.parse_timespan(bad)
    },
  )
}

// ---- export ---------------------------------------------------------------------

/// Replaces the value of metadata.generator.version. It is the package
/// version, which every release PR bumps, so the golden comparison ignores it.
fn without_generator_version(cue: String) -> String {
  let #(_, lines) =
    list.map_fold(string.split(cue, "\n"), False, fn(in_generator, line) {
      case in_generator, string.trim(line) {
        _, "generator: {" -> #(True, line)
        True, "}" -> #(False, line)
        True, "version: " <> _ -> #(True, "version: <generator-version>")
        _, _ -> #(in_generator, line)
      }
    })
  string.join(lines, "\n")
}

pub fn export_golden_test() {
  let assert Ok(cue) = docuconf.contract(sample.spec(), name: "sample-gateway")
  let golden = "test/golden/sample.cue"
  case envoy.get("UPDATE_GOLDEN") {
    Ok("1") -> support.write(golden, string.drop_end(cue, 1))
    _ -> Nil
  }
  let assert True =
    without_generator_version(cue)
    == without_generator_version(support.sh("cat " <> golden))
  let assert True =
    string.starts_with(
      cue,
      "// Code generated by docuconf. DO NOT EDIT.\npackage sample_gateway\n",
    )
}

pub fn golden_comparison_ignores_only_the_generator_version_test() {
  let assert Ok(cue) = docuconf.contract(sample.spec(), name: "sample-gateway")
  let bumped =
    string.replace(
      cue,
      "version: \"" <> cue_writer.sdk_version <> "\"",
      "version: \"99.0.0\"",
    )
  let assert True = bumped != cue
  let assert True =
    without_generator_version(bumped) == without_generator_version(cue)
  let assert True =
    without_generator_version(string.replace(cue, "\"gleam\"", "\"erlang\""))
    != without_generator_version(cue)
}

pub fn export_options_test() {
  let assert Ok(cue) =
    docuconf.contract_with(
      sample.spec(),
      "sample-gateway",
      Some("gw"),
      Some("1.2.3"),
    )
  let assert True = string.contains(cue, "\npackage gw\n")
  let assert True = string.contains(cue, "appVersion: \"1.2.3\"")
  let assert Error(docuconf.InvalidDeclaration(_)) =
    docuconf.contract(sample.spec(), name: "Not_A_Label")
}

/// cue vet -c against the meta-schema from docuconf-go (DOCUCONF_SPEC_CUE,
/// else a sibling checkout). Skipped when cue or the spec is absent, unless
/// DOCUCONF_REQUIRE_VET=1.
pub fn export_cue_vet_test() {
  let assert Ok(contract) =
    docuconf.contract(sample.spec(), name: "sample-gateway")
  cue_vet(contract)
}

fn cue_vet(contract: String) -> Nil {
  let spec_dir = case envoy.get("DOCUCONF_SPEC_CUE") {
    Ok(d) -> d
    Error(Nil) -> "../docuconf-go/spec/cue"
  }
  let cue_bin = case support.has("cue") {
    True -> Some("cue")
    False ->
      case support.shell("test -x \"$HOME/go/bin/cue\"").0 {
        0 -> Some("\"$HOME/go/bin/cue\"")
        _ -> None
      }
  }
  let spec_ok = support.shell("test -d '" <> spec_dir <> "/contract'").0 == 0
  case cue_bin, spec_ok {
    Some(cue), True -> {
      let dir = support.temp_dir()
      let _ =
        support.sh(
          "cp -r '"
          <> spec_dir
          <> "/cue.mod' '"
          <> spec_dir
          <> "/contract' "
          <> dir
          <> "/",
        )
      support.write(dir <> "/svc/contract.cue", contract)
      let #(code, out) =
        support.shell("cd " <> dir <> " && " <> cue <> " vet -c ./svc 2>&1")
      case code {
        0 -> Nil
        _ -> panic as { "cue vet failed:\n" <> out <> "\n" <> contract }
      }
    }
    _, _ ->
      case envoy.get("DOCUCONF_REQUIRE_VET") {
        Ok("1") -> panic as "cue or the docuconf meta-schema is missing"
        _ -> Nil
      }
  }
}

// ---- variables ------------------------------------------------------------------

pub fn typed_values_and_defaults_test() {
  let root = file_root()
  let assert Ok(s) = load(root, [])
  let assert 8080 = s.port
  let assert None = s.gomemlimit
  let assert 0.25 = s.sample_rate
  let assert False = s.debug
  let assert 30_000 = duration.to_milliseconds(s.request_timeout)
  let assert sample.LogInfo = s.log_level
  let assert ["https://a.example.com"] = s.allowed_origins

  let assert Ok(s) =
    load(root, [
      #("PORT", "9090"),
      #("SAMPLE_RATE", "1e-1"),
      #("DEBUG", "TRUE"),
      #("REQUEST_TIMEOUT", "1m30s"),
      #("LOG_LEVEL", "debug"),
      #("WORKER_PORTS", "1;2;3"),
      #("RATE_LIMITS", "{\"perMinute\": 10}"),
      #("KEYSTORE_PASSWORD", "pw"),
    ])
  let assert 9090 = s.port
  let assert 0.1 = s.sample_rate
  let assert True = s.debug
  let assert 90_000 = duration.to_milliseconds(s.request_timeout)
  let assert sample.LogDebug = s.log_level
  let assert Some([1, 2, 3]) = s.worker_ports
  let assert Some(sample.RateLimits(10, None)) = s.rate_limits
  let assert [sample.Route("/api", "https://api.internal", Some("5s"))] =
    s.routes
  let assert "ABCDE-12345-FGHIJ-67890\n" = s.license
}

pub fn empty_is_unset_except_for_strings_test() {
  let root = file_root()
  let assert Ok(s) = load(root, [#("PORT", ""), #("DEBUG", "")])
  let assert 8080 = s.port
  let assert [#("DATABASE_URL", "missing_required")] =
    codes(load(root, [#("DATABASE_URL", "")]))
  // An empty string is a present value for strings, and fails min_length.
  let assert [#("REGION", "out_of_range")] =
    codes(load(root, [#("REGION", "")]))
}

pub fn all_violations_together_test() {
  let root = file_root()
  let result =
    load(root, [
      #("DATABASE_URL", ""),
      #("PORT", "70000"),
      #("SAMPLE_RATE", "NaN"),
      #("DEBUG", "yes"),
      #("REQUEST_TIMEOUT", "10m"),
      #("LOG_LEVEL", "trace"),
      #("ALLOWED_ORIGINS", ""),
      #("WORKER_PORTS", "1;x"),
      #("RATE_LIMITS", "{\"perMinute\": \"lots\"}"),
      #("REGION", "west"),
      #("PUBLIC_URL", "http://gw"),
      #("GOMEMLIMIT", "1.5"),
    ])
  let assert [
    #("ALLOWED_ORIGINS", "missing_required"),
    #("DATABASE_URL", "missing_required"),
    #("DEBUG", "invalid_type"),
    #("GOMEMLIMIT", "invalid_type"),
    #("LOG_LEVEL", "not_in_enum"),
    #("PORT", "out_of_range"),
    #("PUBLIC_URL", "invalid_scheme"),
    #("RATE_LIMITS", "schema_mismatch"),
    #("REGION", "pattern_mismatch"),
    #("REQUEST_TIMEOUT", "out_of_range"),
    #("SAMPLE_RATE", "invalid_type"),
    #("WORKER_PORTS", "invalid_type"),
  ] = codes(result)
  let assert Error(e) = result
  let text = docuconf.describe(e)
  let assert True =
    string.contains(text, "docuconf: 12 configuration problems:")
  let assert True =
    string.contains(text, "PORT [out_of_range]: \"70000\" is above max 65535")
}

// SPEC §4.3, §5: itemMin and itemMax bound each item of an int list.
pub fn item_bounds_test() {
  let spec = {
    use shards <- docuconf.env(
      docuconf.int_list(
        "SHARDS",
        "Shard ids this instance owns",
        separator: ",",
      )
      |> docuconf.item_min(0)
      |> docuconf.item_max(1023)
      |> docuconf.optional,
    )
    docuconf.succeed(shards)
  }
  let load = fn(v) {
    docuconf.load_with(
      spec,
      docuconf.options()
        |> docuconf.with_env(dict.from_list([#("SHARDS", v)]))
        |> docuconf.without_termination_log,
    )
  }
  let assert Ok(Some([0, 7, 1023])) = load("0,7,1023")
  let assert [#("SHARDS", "out_of_range")] = codes(load("3,-1"))
  let assert [#("SHARDS", "out_of_range")] = codes(load("1024"))
  let assert [#("SHARDS", "invalid_type")] = codes(load("1,x"))
  let assert Ok(cue) = docuconf.contract(spec, name: "shards")
  let assert True =
    string.contains(cue, "\t\t\titemMin: 0\n\t\t\titemMax: 1023\n")
  cue_vet(cue)
  // A default must respect the bounds.
  let bad_default = {
    use shards <- docuconf.env(
      docuconf.int_list(
        "SHARDS",
        "Shard ids this instance owns",
        separator: ",",
      )
      |> docuconf.item_max(3)
      |> docuconf.default([1, 4]),
    )
    docuconf.succeed(shards)
  }
  let assert [_] = docuconf.check_declaration(bad_default)
}

pub fn bad_int_test() {
  let root = file_root()
  let assert [#("PORT", "invalid_type")] =
    codes(load(root, [#("PORT", "80.5")]))
  let assert [#("PORT", "out_of_range")] =
    codes(load(root, [#("PORT", "99999999999999999999")]))
  // Values are never trimmed.
  let assert [#("PORT", "invalid_type")] =
    codes(load(root, [#("PORT", "8080\n")]))
}

pub fn secret_redaction_test() {
  let root = file_root()
  let result =
    load(root, [
      #("DATABASE_URL", "mysql://admin:hunter2@db/x"),
      #("KEYSTORE_PASSWORD", ""),
    ])
  let assert [
    #("DATABASE_URL", "invalid_scheme"),
    #("KEYSTORE_PASSWORD", "out_of_range"),
  ] = codes(result)
  let assert Error(e) = result
  let text = docuconf.describe(e)
  let assert False = string.contains(text, "hunter2")
  let assert False = string.contains(text, "mysql")
}

pub fn termination_log_test() {
  let root = file_root()
  let log = root <> "/termination-log"
  let opts =
    docuconf.options()
    |> docuconf.with_env(
      dict.from_list([
        #("PORT", "x"),
        #("DATABASE_URL", "postgres://u:s3cr3t@h/d"),
      ]),
    )
    |> docuconf.with_file_root(root)
    |> docuconf.with_termination_log(log)
  let assert Error(_) = docuconf.load_with(sample.spec(), opts)
  let written = support.sh("cat " <> log)
  let assert True = string.contains(written, "PORT [invalid_type]")
  let assert True = string.contains(written, "REGION [missing_required]")
  let assert False = string.contains(written, "s3cr3t")
}

pub fn unresolved_injector_reference_test() {
  let root = file_root()
  let log = root <> "/termination-log"
  let vault = "vault:secret/data/gateway#database_url"
  let op = "op://prod/partner/keystore-password"
  let opts =
    docuconf.options()
    |> docuconf.with_env(
      dict.from_list(
        list.append(base_env(), [
          #("DATABASE_URL", vault),
          #("KEYSTORE_PASSWORD", op),
        ]),
      ),
    )
    |> docuconf.with_file_root(root)
    |> docuconf.with_termination_log(log)
  let result = docuconf.load_with(sample.spec(), opts)
  let assert Error(docuconf.InvalidConfig(vs) as e) = result
  let assert [
    #(
      "DATABASE_URL",
      "invalid_type",
      "holds an unresolved vault: reference; the injector that should resolve it did not run",
    ),
    #(
      "KEYSTORE_PASSWORD",
      "invalid_type",
      "holds an unresolved op:// reference; the injector that should resolve it did not run",
    ),
  ] =
    list.map(vs, fn(v: docuconf.Violation) {
      #(v.input, docuconf.code_to_string(v.code), v.message)
    })
  let text = docuconf.describe(e)
  let written = support.sh("cat " <> log)
  let assert True =
    string.contains(
      written,
      "DATABASE_URL [invalid_type]: holds an unresolved vault: reference",
    )
  list.each([vault, op, "secret/data", "prod/partner"], fn(value) {
    let assert False = string.contains(text, value)
    let assert False = string.contains(written, value)
  })
  let assert [#("KEYSTORE_PASSWORD", "invalid_type")] =
    codes(load(root, [#("KEYSTORE_PASSWORD", "ref+awsssm://prod/password")]))
  // Only secrets, and only a prefix.
  let assert [#("REGION", "pattern_mismatch")] =
    codes(load(root, [#("REGION", "vault:eu-west-1")]))
  let assert [#("KEYSTORE_PASSWORD", "invalid_type")] =
    codes(load(root, [#("KEYSTORE_PASSWORD", "vault:")]))
}

// ---- declarations -----------------------------------------------------------------

pub fn declaration_problems_test() {
  let bad = {
    use _ <- docuconf.env(
      docuconf.int("port", "HTTP port") |> docuconf.default(0),
    )
    use _ <- docuconf.env(
      docuconf.int("SIZE", "size")
      |> docuconf.min_int(10)
      |> docuconf.default(3),
    )
    use _ <- docuconf.env(
      docuconf.string("TOKEN", "API token")
      |> docuconf.secret
      |> docuconf.default("x"),
    )
    use _ <- docuconf.env(
      docuconf.string("HOST", "Host name")
      |> docuconf.pattern("a(?=b)")
      |> docuconf.optional,
    )
    use _ <- docuconf.env(
      docuconf.url("API", "API base URL")
      |> docuconf.min_length(3)
      |> docuconf.optional,
    )
    use _ <- docuconf.file(
      docuconf.text("a", "First file", path: "/etc/svc/conf/a.txt")
      |> docuconf.file_optional,
    )
    use _ <- docuconf.file(
      docuconf.text("b", "Second file", path: "/etc/svc/conf/b.txt")
      |> docuconf.path_env("HOST")
      |> docuconf.file_optional,
    )
    use _ <- docuconf.file(
      docuconf.ca_bundle("ca", "CA bundle", path: "/etc/ssl/certs/private.pem")
      |> docuconf.file_optional,
    )
    use _ <- docuconf.file(
      docuconf.keystore(
        "ks",
        "A keystore",
        path: "/etc/svc/ks/ks.p12",
        format: docuconf.Pkcs12,
        password_var: Some("SIZE"),
      )
      |> docuconf.file_optional,
    )
    use _ <- docuconf.file(
      docuconf.binary("Bad", "Bad name", path: "relative/path")
      |> docuconf.file_optional,
    )
    docuconf.succeed(Nil)
  }
  let text = string.join(docuconf.check_declaration(bad), "\n")
  let expect = fn(s) {
    case string.contains(text, s) {
      True -> Nil
      False -> panic as { "missing problem: " <> s <> "\n" <> text }
    }
  }
  expect("variable port: name must match")
  expect("variable SIZE: description is required")
  expect(
    "variable SIZE: default does not satisfy the variable's constraints (out_of_range",
  )
  expect("variable TOKEN: a secret must not have a default")
  expect("variable HOST: pattern \"a(?=b)\" uses lookahead")
  expect("variable API: min_length does not apply to a url variable")
  expect("file b: path_env HOST must not also be declared as a variable")
  expect("file ca: would be mounted at reserved directory /etc/ssl/certs")
  expect("file ks: password_var SIZE must name a declared secret variable")
  expect("file Bad: input name must be a DNS label")
  expect("file Bad: path must be absolute")
  expect("file inputs a, b share mount directory /etc/svc/conf")
  let assert Error(docuconf.InvalidDeclaration(_)) =
    docuconf.load_with(bad, docuconf.options() |> docuconf.with_env(dict.new()))
  let assert [] = docuconf.check_declaration(sample.spec())
}

pub fn feature_flag_warning_test() {
  let flags = {
    use _ <- docuconf.env(
      docuconf.bool("ENABLE_CHECKOUT", "New checkout flow")
      |> docuconf.default(False),
    )
    use _ <- docuconf.env(
      docuconf.bool("FF_KILL", "Kill switch")
      |> docuconf.deploy_time_switch
      |> docuconf.default(False),
    )
    docuconf.succeed(Nil)
  }
  let assert [warning] = docuconf.flag_warnings(flags)
  let assert True =
    string.starts_with(warning, "ENABLE_CHECKOUT looks like a feature flag")
}

// ---- files ------------------------------------------------------------------

pub fn valid_files_test() {
  let root = file_root()
  let assert Ok(s) = load(root, [])
  let assert True =
    s.serving_tls.cert_file == root <> "/etc/gateway/tls/tls.crt"
  let assert Some(_) = s.serving_tls.ca_file
  let assert None = s.upstream_ca
  let assert None = s.geoip
}

pub fn path_env_with_file_root_test() {
  let root = file_root()
  support.write(
    root <> "/elsewhere/routes.json",
    "{\"routes\": [{\"match\": \"/x\", \"upstream\": \"http://x\"}]}",
  )
  let assert Ok(s) = load(root, [#("ROUTES_FILE", "/elsewhere/routes.json")])
  let assert [sample.Route("/x", "http://x", None)] = s.routes
}

pub fn missing_required_file_test() {
  let root = file_root()
  let _ = support.sh("rm " <> root <> "/etc/gateway/license/license.key")
  let _ = support.sh("rm " <> root <> "/etc/gateway/tls/tls.key")
  let assert [#("license", "file_missing"), #("serving-tls", "file_missing")] =
    codes(load(root, []))
}

pub fn malformed_config_and_schema_mismatch_test() {
  let root = file_root()
  support.write(root <> "/etc/gateway/routes/routes.json", "{\"routes\": [")
  let assert [#("routes", "file_malformed")] = codes(load(root, []))
  support.write(
    root <> "/etc/gateway/routes/routes.json",
    "{\"routes\": [{\"match\": 1}]}",
  )
  let assert [#("routes", "schema_mismatch")] = codes(load(root, []))
}

pub fn file_too_large_and_text_pattern_test() {
  let root = file_root()
  let _ =
    support.sh(
      "head -c 70000 /dev/zero | tr '\\0' ' ' > "
      <> root
      <> "/etc/gateway/routes/routes.json",
    )
  support.write(root <> "/etc/gateway/license/license.key", "nope")
  let assert [#("license", "pattern_mismatch"), #("routes", "file_too_large")] =
    codes(load(root, []))
}

pub fn ca_bundle_test() {
  let root = file_root()
  support.write(root <> "/etc/gateway/ca/bundle.pem", "not a pem")
  let assert [#("upstream-ca", "file_malformed")] = codes(load(root, []))
  let _ =
    support.sh(
      "cp " <> root <> "/pki/ca.crt " <> root <> "/etc/gateway/ca/bundle.pem",
    )
  let assert Ok(s) = load(root, [])
  let assert Some(docuconf.CaBundle(_, 1)) = s.upstream_ca
}

pub fn expiring_and_expired_certificate_test() {
  let root = file_root()
  // The leaf is valid for 90 days; minRemaining is 720h (30 days).
  let day = 86_400
  let assert [#("serving-tls", "certificate_expiring")] =
    codes(load_at(root, [], Some(now() + 70 * day)))
  let assert [#("serving-tls", "certificate_invalid")] =
    codes(load_at(root, [], Some(now() + 100 * day)))
  let assert [#("serving-tls", "certificate_invalid")] =
    codes(load_at(root, [], Some(now() - 10 * day)))
}

pub fn dns_mismatch_test() {
  let root = file_root()
  support.make_leaf(
    root <> "/pki",
    root <> "/etc/gateway/tls",
    "gateway.internal",
    90,
    "ec",
  )
  let assert [#("serving-tls", "certificate_name_mismatch")] =
    codes(load(root, []))
  // A wildcard covers one label.
  support.make_leaf(
    root <> "/pki",
    root <> "/etc/gateway/tls",
    "gateway.internal,*.example.com",
    90,
    "ec",
  )
  let assert Ok(_) = load(root, [])
}

pub fn key_mismatch_test() {
  let root = file_root()
  let other = root <> "/other"
  support.make_leaf(
    root <> "/pki",
    other,
    "gateway.internal,api.example.com",
    90,
    "ec",
  )
  let _ =
    support.sh(
      "cp " <> other <> "/tls.key " <> root <> "/etc/gateway/tls/tls.key",
    )
  let assert [#("serving-tls", "key_mismatch")] = codes(load(root, []))
}

pub fn key_algorithm_and_chain_test() {
  let root = file_root()
  let tls = root <> "/etc/gateway/tls"
  let names = "gateway.internal,api.example.com"
  support.make_leaf(root <> "/pki", tls, names, 90, "rsa:2048")
  let assert Ok(_) = load(root, [])
  support.make_leaf(root <> "/pki", tls, names, 90, "ed25519")
  let assert [#("serving-tls", "certificate_invalid")] = codes(load(root, []))
  // A different CA in ca.crt breaks the chain.
  support.make_leaf(root <> "/pki", tls, names, 90, "ec")
  let other_ca = root <> "/pki2"
  let _ = support.sh("mkdir -p " <> other_ca)
  support.make_ca(other_ca)
  let _ = support.sh("cp " <> other_ca <> "/ca.crt " <> tls <> "/ca.crt")
  let assert [#("serving-tls", "certificate_invalid")] = codes(load(root, []))
}

pub fn keystore_format_test() {
  let root = file_root()
  support.write(root <> "/etc/gateway/partner/keystore.p12", "garbage")
  let assert [#("partner-keystore", "keystore_unreadable")] =
    codes(load(root, [#("KEYSTORE_PASSWORD", "changeit")]))
}

/// Exports the TLS key pair under root as a PKCS#12 file at `out`.
fn make_p12(root: String, out: String, password: String, args: String) -> Nil {
  let tls = root <> "/etc/gateway/tls"
  let _ =
    support.sh(
      "mkdir -p \"$(dirname '"
      <> out
      <> "')\" && openssl pkcs12 -export -in "
      <> tls
      <> "/tls.crt -inkey "
      <> tls
      <> "/tls.key -out '"
      <> out
      <> "' -passout 'pass:"
      <> password
      <> "' "
      <> args
      <> " 2>&1",
    )
  Nil
}

fn keystore_message(result) -> String {
  let assert Error(docuconf.InvalidConfig([v])) = result
  let assert "keystore_unreadable" = docuconf.code_to_string(v.code)
  v.message
}

pub fn keystore_password_test() {
  let root = file_root()
  let p12 = root <> "/etc/gateway/partner/keystore.p12"
  // OpenSSL 3 defaults (SHA-256 MAC), the legacy SHA-1 MAC and SHA-512.
  list.each(["", "-macalg sha1", "-macalg sha512 -iter 4096"], fn(args) {
    make_p12(root, p12, "changeit", args)
    let assert Ok(cfg) = load(root, [#("KEYSTORE_PASSWORD", "changeit")])
    let assert Some(_) = cfg.partner_keystore
    let msg =
      keystore_message(load(root, [#("KEYSTORE_PASSWORD", "wrong-password")]))
    let assert True =
      string.contains(
        msg,
        "cannot open the pkcs12 keystore with the password from KEYSTORE_PASSWORD (wrong password or corrupted file: the integrity MAC does not match)",
      )
    let assert False = string.contains(msg, "wrong-password")
    // Unset password variable: an empty password, which is wrong here.
    let _ = keystore_message(load(root, []))
  })
  // Without a MAC the password cannot be checked.
  make_p12(root, p12, "changeit", "-nomac")
  let assert True =
    string.contains(
      keystore_message(load(root, [#("KEYSTORE_PASSWORD", "changeit")])),
      "has no integrity MAC",
    )
  // A corrupted file fails the MAC even with the right password.
  make_p12(root, p12, "changeit", "")
  let _ =
    support.sh(
      "printf '\\377' | dd of='"
      <> p12
      <> "' bs=1 seek=200 conv=notrunc 2>/dev/null",
    )
  let _ = keystore_message(load(root, [#("KEYSTORE_PASSWORD", "changeit")]))
}

pub fn keystore_empty_password_test() {
  let root = file_root()
  let p12 = root <> "/ks/store.p12"
  make_p12(root, p12, "", "")
  let spec = fn(var) {
    use ks <- docuconf.file(
      docuconf.keystore(
        "store",
        "A keystore with no password",
        path: "/ks/store.p12",
        format: docuconf.Pkcs12,
        password_var: var,
      )
      |> docuconf.file_required,
    )
    use _ <- docuconf.env(
      docuconf.string("STORE_PASSWORD", "Password for the keystore")
      |> docuconf.secret
      |> docuconf.optional,
    )
    docuconf.succeed(ks)
  }
  let opts = fn(env) {
    docuconf.options()
    |> docuconf.with_env(dict.from_list(env))
    |> docuconf.with_file_root(root)
    |> docuconf.without_termination_log
  }
  let assert Ok(path) = docuconf.load_with(spec(None), opts([]))
  let assert True = string.ends_with(path, "/ks/store.p12")
  let assert Ok(_) = docuconf.load_with(spec(Some("STORE_PASSWORD")), opts([]))
  let assert Error(_) =
    docuconf.load_with(
      spec(Some("STORE_PASSWORD")),
      opts([#("STORE_PASSWORD", "x")]),
    )
}

pub fn keystore_jks_test() {
  case support.has("keytool") {
    False -> Nil
    True -> {
      let root = file_root()
      let p12 = root <> "/src.p12"
      make_p12(root, p12, "changeit", "-name leaf")
      let spec = fn(path) {
        use ks <- docuconf.file(
          docuconf.keystore(
            "store",
            "A Java keystore",
            path: path,
            format: docuconf.Jks,
            password_var: Some("STORE_PASSWORD"),
          )
          |> docuconf.file_required,
        )
        use _ <- docuconf.env(
          docuconf.string("STORE_PASSWORD", "Password for the keystore")
          |> docuconf.secret
          |> docuconf.optional,
        )
        docuconf.succeed(ks)
      }
      list.each(["JKS", "JCEKS"], fn(kind) {
        let out = "/ks/" <> string.lowercase(kind) <> "/store.jks"
        let _ =
          support.sh(
            "mkdir -p \"$(dirname '"
            <> root
            <> out
            <> "')\" && keytool -importkeystore -noprompt -srckeystore "
            <> p12
            <> " -srcstoretype PKCS12 -srcstorepass changeit -destkeystore '"
            <> root
            <> out
            <> "' -deststoretype "
            <> kind
            <> " -deststorepass changeit 2>&1",
          )
        let opts = fn(pw) {
          docuconf.options()
          |> docuconf.with_env(dict.from_list([#("STORE_PASSWORD", pw)]))
          |> docuconf.with_file_root(root)
          |> docuconf.without_termination_log
        }
        let assert Ok(_) = docuconf.load_with(spec(out), opts("changeit"))
        let assert True =
          string.contains(
            keystore_message(docuconf.load_with(spec(out), opts("nope-nope"))),
            "the integrity digest does not match",
          )
      })
    }
  }
}

pub fn every_violation_vars_and_files_test() {
  let root = file_root()
  let _ = support.sh("rm " <> root <> "/etc/gateway/license/license.key")
  support.write(root <> "/etc/gateway/routes/routes.json", "{}")
  let assert [
    #("PORT", "invalid_type"),
    #("license", "file_missing"),
    #("routes", "schema_mismatch"),
  ] = codes(load(root, [#("PORT", "abc")]))
}

pub fn int64_range_test() {
  let spec = {
    use n <- docuconf.env(
      docuconf.int("N", "A big number") |> docuconf.required,
    )
    docuconf.succeed(n)
  }
  let load = fn(v) {
    docuconf.load_with(
      spec,
      docuconf.options()
        |> docuconf.with_env(dict.from_list([#("N", v)]))
        |> docuconf.without_termination_log,
    )
  }
  let assert [#("N", "out_of_range")] = codes(load("9223372036854775808"))
  let assert [#("N", "out_of_range")] = codes(load("-9223372036854775809"))
  let assert [#("N", "out_of_range")] = codes(load("99999999999999999999"))
  let assert [#("N", "invalid_type")] = codes(load("1e3"))
  case support.target() {
    "erlang" -> {
      let assert Ok(n) = load("9223372036854775807")
      let assert "9223372036854775807" = int.to_string(n)
      let assert Ok(n) = load("-9223372036854775808")
      let assert "-9223372036854775808" = int.to_string(n)
      Nil
    }
    _ -> Nil
  }
}

// SPEC §5: on JavaScript an Int is exact only within ±(2^53 - 1), so the
// export bounds every int variable to that range and the boot check rejects
// values beyond it, instead of rounding them.
pub fn javascript_int_range_test() {
  let max = 9_007_199_254_740_991
  // 2^53, built at runtime: the literal is not safe on JavaScript.
  let two_53 = max + 1
  let unbounded = {
    use n <- docuconf.env(
      docuconf.int("N", "A big number") |> docuconf.optional,
    )
    use ns <- docuconf.env(
      docuconf.int_list("NS", "Big numbers", separator: ",")
      |> docuconf.optional,
    )
    docuconf.succeed(#(n, ns))
  }
  let load = fn(spec, env) {
    docuconf.load_with(
      spec,
      docuconf.options()
        |> docuconf.with_env(dict.from_list(env))
        |> docuconf.without_termination_log,
    )
  }
  let assert Ok(cue) = docuconf.contract(unbounded, name: "ints")
  let narrowed = {
    use n <- docuconf.env(
      docuconf.int("N", "A big number")
      |> docuconf.min_int(1)
      |> docuconf.optional,
    )
    docuconf.succeed(n)
  }
  let assert Ok(narrowed_cue) = docuconf.contract(narrowed, name: "ints")
  let wide = {
    use n <- docuconf.env(
      docuconf.int("N", "A big number")
      |> docuconf.min_int(-two_53)
      |> docuconf.max_int(two_53)
      |> docuconf.optional,
    )
    docuconf.succeed(n)
  }
  case support.target() {
    "javascript" -> {
      let assert True =
        string.contains(
          cue,
          "\t\t\tmin: -9007199254740991\n\t\t\tmax: 9007199254740991\n",
        )
      let assert True =
        string.contains(
          narrowed_cue,
          "\t\t\tmin: 1\n\t\t\tmax: 9007199254740991\n",
        )
      let assert Ok(#(Some(n), None)) =
        load(unbounded, [#("N", "9007199254740991")])
      let assert True = n == max
      let assert Ok(#(Some(n), None)) =
        load(unbounded, [#("N", "-9007199254740991")])
      let assert True = n == -max
      let assert [#("N", "out_of_range"), #("NS", "out_of_range")] =
        codes(
          load(unbounded, [
            #("N", "9007199254740993"),
            #("NS", "1,9007199254740992"),
          ]),
        )
      let assert [#("N", "out_of_range")] =
        codes(load(unbounded, [#("N", "-9007199254740992")]))
      // int lists carry the same range through itemMin and itemMax.
      let assert True =
        string.contains(
          cue,
          "\t\t\titemMin: -9007199254740991\n\t\t\titemMax: 9007199254740991\n",
        )
      cue_vet(cue)
      let assert [_, _] = docuconf.check_declaration(wide)
      let wide_items = {
        use ns <- docuconf.env(
          docuconf.int_list("NS", "Big numbers", separator: ",")
          |> docuconf.item_min(-two_53)
          |> docuconf.item_max(two_53)
          |> docuconf.optional,
        )
        docuconf.succeed(ns)
      }
      let assert [_, _] = docuconf.check_declaration(wide_items)
      let defaulted = {
        use n <- docuconf.env(
          docuconf.int("N", "A big number")
          |> docuconf.default(two_53),
        )
        docuconf.succeed(n)
      }
      let assert [_] = docuconf.check_declaration(defaulted)
      Nil
    }
    _ -> {
      let assert False = string.contains(cue, "min")
      let assert False = string.contains(cue, "max")
      let assert False = string.contains(cue, "itemM")
      let assert Ok(#(Some(n), Some([1, m]))) =
        load(unbounded, [
          #("N", "9007199254740993"),
          #("NS", "1,9007199254740992"),
        ])
      let assert "9007199254740993" = int.to_string(n)
      let assert True = m == two_53
      let assert [] = docuconf.check_declaration(wide)
      Nil
    }
  }
}

fn matches(pattern: String, value: String) -> Bool {
  let spec = {
    use v <- docuconf.env(
      docuconf.string("V", "A value")
      |> docuconf.pattern(pattern)
      |> docuconf.required,
    )
    docuconf.succeed(v)
  }
  let opts =
    docuconf.options()
    |> docuconf.with_env(dict.from_list([#("V", value)]))
    |> docuconf.without_termination_log
  case docuconf.load_with(spec, opts) {
    Ok(_) -> True
    Error(docuconf.InvalidConfig(_)) -> False
    Error(docuconf.InvalidDeclaration(ps)) -> panic as string.join(ps, "; ")
  }
}

pub fn re2_semantics_test() {
  // Partial match; anchors are explicit.
  let assert True = matches("b", "abc")
  let assert False = matches("^b", "abc")
  // $ is the end of the text, not "before a final newline".
  let assert False = matches("^abc$", "abc\n")
  let assert True = matches("^abc\\n?$", "abc\n")
  // \d, \w and \s are ASCII-only, as in RE2.
  let assert False = matches("^\\d$", "٣")
  let assert False = matches("^\\w$", "é")
  let assert False = matches("^\\s$", "\u{00A0}")
  let assert True = matches("^\\d\\w\\s$", "1a ")
  let assert True = matches("\\bfoo\\b", "a foo b")
  let assert False = matches("\\bfoo\\b", "afoob")
  let assert True = matches("^(?P<x>a)\\z", "a")
}

pub fn indexed_list_gap_test() {
  let spec = {
    use ports <- docuconf.env(
      docuconf.int_list_with(
        "PORTS",
        "Worker ports",
        encoding: docuconf.Indexed,
      )
      |> docuconf.optional,
    )
    use hosts <- docuconf.env(
      docuconf.string_list_with(
        "HOSTS",
        "Upstream hosts",
        encoding: docuconf.Indexed,
      )
      |> docuconf.optional,
    )
    docuconf.succeed(#(ports, hosts))
  }
  let load = fn(env) {
    docuconf.options()
    |> docuconf.with_env(dict.from_list(env))
    |> docuconf.without_termination_log
    |> docuconf.load_with(spec, _)
  }
  let assert Ok(#(Some([80, 81]), Some(["a"]))) =
    load([
      #("PORTS__0", "80"),
      #("PORTS__1", "81"),
      #("HOSTS__0", "a"),
      #("HOSTS__HOST", "not an item"),
      #("HOSTS__01", "not an item"),
    ])
  let assert Ok(#(None, None)) = load([#("HOSTS__X", "not an item")])
  let assert Error(docuconf.InvalidConfig([start, gap])) =
    load([#("PORTS__0", "80"), #("PORTS__2", "82"), #("HOSTS__1", "b")])
  let assert docuconf.Violation(
    "PORTS",
    _,
    docuconf.InvalidType,
    "items must be numbered from PORTS__0 with no gap, but PORTS__1 is not set",
  ) = gap
  let assert docuconf.Violation("HOSTS", _, docuconf.InvalidType, _) = start
}

// ---- contract-first -------------------------------------------------------------

const orders_contract = "{
  \"apiVersion\": \"docuconf.dev/v1alpha1\",
  \"kind\": \"ConfigContract\",
  \"metadata\": {\"name\": \"orders\", \"generator\": {\"language\": \"go\", \"sdk\": \"docuconf-go\", \"version\": \"0.1.0\"}},
  \"vars\": {
    \"PORT\": {\"type\": \"int\", \"description\": \"HTTP listen port\", \"min\": 1, \"max\": 65535, \"default\": 8080},
    \"BROKERS\": {\"type\": \"list\", \"description\": \"Kafka bootstrap servers\", \"items\": \"string\", \"encoding\": \"indexed\", \"required\": true, \"minItems\": 1},
    \"PARTITIONS\": {\"type\": \"list\", \"description\": \"Partitions this instance consumes\", \"items\": \"int\", \"encoding\": \"json\", \"itemMin\": 0, \"itemMax\": 63},
    \"TIMEOUT\": {\"type\": \"duration\", \"description\": \"Checkout timeout\", \"encoding\": \"iso8601\", \"max\": \"1m\", \"default\": \"15s\"},
    \"DRAIN\": {\"type\": \"duration\", \"description\": \"Time to drain\", \"encoding\": \"timespan\"},
    \"RATIO\": {\"type\": \"float\", \"description\": \"Sample ratio\", \"min\": 0, \"max\": 1},
    \"LEVEL\": {\"type\": \"enum\", \"description\": \"Log level\", \"values\": [\"debug\", \"info\"], \"default\": \"info\"},
    \"TOKEN\": {\"type\": \"string\", \"description\": \"API token\", \"secret\": true, \"minLength\": 10},
    \"LIMITS\": {\"type\": \"json\", \"description\": \"Rate limits\", \"schema\": {\"type\": \"object\"}}
  }
}"

pub fn contract_first_test() {
  let load = docuconf_contract_first_load
  let assert Ok(values) =
    load([
      #("BROKERS__0", "kafka-0:9092"),
      #("BROKERS__1", "kafka-1:9092"),
      #("BROKERS__HOST", "not an item"),
      #("PARTITIONS", "[0, 7]"),
      #("TIMEOUT", "PT30.5S"),
      #("DRAIN", "00:01:30"),
      #("RATIO", "0.5"),
      #("TOKEN", "0123456789abc"),
      #("LIMITS", "{\"perMinute\": 60}"),
    ])
  let get = fn(name) {
    let assert Ok(v) = dict.get(values, name)
    json.to_string(contract_first.to_json(v))
  }
  let assert "8080" = get("PORT")
  let assert "[\"kafka-0:9092\",\"kafka-1:9092\"]" = get("BROKERS")
  let assert "[0,7]" = get("PARTITIONS")
  let assert "\"30s500ms\"" = get("TIMEOUT")
  let assert "\"1m30s\"" = get("DRAIN")
  let assert "\"info\"" = get("LEVEL")
  let assert "\"0123456789abc\"" = get("TOKEN")
  let assert "{\"perMinute\":60}" = get("LIMITS")
  let assert Ok(contract_first.FloatValue(0.5)) = dict.get(values, "RATIO")
  let assert Ok(contract_first.IntValue(8080)) = dict.get(values, "PORT")
  // Every problem together, with the same codes as a declaration.
  let assert Error(docuconf.InvalidConfig(vs) as e) =
    load([
      #("PARTITIONS", "[1, 64]"),
      #("TIMEOUT", "2m"),
      #("DRAIN", "25:00:00"),
      #("LEVEL", "trace"),
      #("TOKEN", "short-tok"),
      #("LIMITS", "{"),
    ])
  let assert [
    #("BROKERS", "missing_required"),
    #("DRAIN", "invalid_type"),
    #("LEVEL", "not_in_enum"),
    #("LIMITS", "invalid_type"),
    #("PARTITIONS", "out_of_range"),
    #("TIMEOUT", "invalid_type"),
    #("TOKEN", "out_of_range"),
  ] = list.map(vs, fn(v) { #(v.input, docuconf.code_to_string(v.code)) })
  let assert False = string.contains(docuconf.describe(e), "short-tok")
  // The contract a contract-first spec exports passes the meta-schema.
  let assert Ok(contract) = json.parse(orders_contract)
  let assert Ok(spec) = contract_first.spec(contract)
  let assert Ok(cue) = docuconf.contract(spec, name: "orders")
  let assert True = string.contains(cue, "encoding: \"indexed\"")
  let assert True = string.contains(cue, "encoding: \"iso8601\"")
  cue_vet(cue)
  // Malformed contracts are declaration errors.
  let assert Error(docuconf.InvalidDeclaration(_)) =
    contract_first.load("{", docuconf.options())
  let assert Error(docuconf.InvalidDeclaration([_, _])) =
    contract_first.load(
      "{\"vars\": {\"A\": {\"type\": \"text\", \"description\": \"Some text\"},"
        <> " \"B\": {\"type\": \"list\", \"items\": \"string\", \"itemMax\": 1, \"description\": \"Some list\"}}}",
      docuconf.options(),
    )
}

fn docuconf_contract_first_load(env: List(#(String, String))) {
  contract_first.load(
    orders_contract,
    docuconf.options()
      |> docuconf.with_env(dict.from_list(env))
      |> docuconf.without_termination_log,
  )
}
