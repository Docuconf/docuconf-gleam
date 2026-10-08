# docuconf for Gleam

Typed configuration contracts for Gleam applications, from the
[docuconf specification](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md) (v1alpha1).

You declare every environment variable and file your app reads, once. From
that declaration you get:

- a typed config value at boot, or **every** problem at once, each with a
  stable error code. Secret values are never printed, and the report also
  goes to `/dev/termination-log`, so `kubectl describe pod` shows it;
- boot checks for files: JSON config decoded into your own type, TLS key
  pairs (key match, expiry, DNS names, key algorithm, chain to `ca.crt`), CA
  bundles, keystores, text and binary files;
- `contract.cue`, a CUE document the platform validates before it deploys.

It runs on both targets: Erlang (OTP 27 or later) and JavaScript (Node.js).
Its only dependencies are `gleam_stdlib` and `envoy`. The package is
`docuconf_gleam`; its modules are `docuconf`, `docuconf/duration`,
`docuconf/json` and `docuconf/contract_first`.

The steps below follow [`examples/orders`](examples/orders), a small wisp
service. Every Gleam snippet in this README is compiled in CI.

## 1. Install

docuconf is not on Hex yet. Depend on it from git, in `gleam.toml`:

```toml
[dependencies]
docuconf_gleam = { git = "https://github.com/docuconf/docuconf-gleam", ref = "main" }
```

Then run `gleam deps download`. To work from a local checkout instead:

```sh
git clone https://github.com/docuconf/docuconf-gleam ../docuconf-gleam
```

```toml
docuconf_gleam = { path = "../docuconf-gleam" }
```

Once the first release is on Hex, `gleam add docuconf_gleam` will do. (The
Hex name `docuconf` belongs to the Elixir SDK.)

## 2. Declare your configuration

One module holds the declaration. Each `use` line declares one variable,
and `build` makes your config from the values:

```gleam
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
```

What to know:

- **A `use` line binds a handle, not a value.** `port` is a
  `fn(Values) -> Int`. Call it inside `build` to get the `Int`:
  `port(v)`. `build` runs once, at load time, after every input has loaded
  and passed its checks. So the declaration never depends on what the
  environment holds: the exported contract lists every variable, and your
  code never runs on a made-up value.
- **Finish every variable** with `required`, `optional` (an `Option`) or
  `default(value)`. If the compiler says it expected `Var(a)` but found
  `VarBuilder(a)`, you forgot to.
- **Secrets** come back as `docuconf.Secret(String)`. `string.inspect`,
  `echo` and crash reports print it as `Secret(//fn() { ... })`;
  `docuconf.reveal` reads the value. Put `secret` after the constraints.
- **Descriptions and details.** The second argument of every constructor
  is the contract's `description`: one line, at least 5 characters.
  `details` (`file_details` for a file) adds longer CommonMark, at most
  4000 characters, on why the input exists and when to change it. Gleam
  cannot read a `///` comment at run time, so details are given
  explicitly; the declaration fails when a description is missing or
  details are blank or too long. `docuconf docs` in the
  [docuconf CLI](https://github.com/docuconf/docuconf-go) generates
  `CONFIG.md` and `CONFIG.agents.md` from the exported contract.
- **To decide on a value, declare first, then decide in `build`.** A
  variable used only when a flag is on is declared `optional` (the
  contract lists it), and `build` reads it when the flag is set. A wrong
  combination can be rejected with `try_map` on one variable, or after
  loading.

## 3. Run it

Load the configuration first thing in `main`:

```gleam
pub fn main() -> Nil {
  // docuconf checks the whole environment before the app starts. On a
  // problem it prints every one at once, each with a stable code, and
  // exits with status 1.
  let config = docuconf.load_or_exit(config.spec())

  wisp.configure_logger()
  wisp.set_logger_level(config.log_level)
  // The secret prints as Secret(//fn() { ... }), never its value.
  wisp.log_info("config: " <> string.inspect(config))
  let assert Ok(_) =
    wisp_mist.handler(handle(_, config), wisp.random_string(64))
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(config.port)
    |> mist.start
  process.sleep_forever()
}
```

`load_or_exit` returns the config, or prints every problem to stderr,
writes the termination log and exits with status 1, on both targets. Use
`load_with` to get a `Result` instead.

## 4. See an error

With `PORT=0` and no `DATABASE_URL`, the service does not start:

```
$ PORT=0 gleam run
docuconf: 2 configuration problems:
  - DATABASE_URL [missing_required]: required, but not set
  - PORT [out_of_range]: "0" is below min 1
```

No stack trace, one line per problem, and a secret's value is never shown.
Warnings go to stderr too, without values: a set variable whose name is
close to a declared one, a secret ending with a newline, list items with
spaces around them:

```
docuconf: warning: DATABSE_URL is set but not declared; did you mean DATABASE_URL?
```

## 5. Test your configuration

`with_env` loads from a map instead of the process environment. Nothing
else is read from the process: no termination log is written and warnings
are dropped (`on_warning` takes them). A gleeunit test, `test/orders_test.gleam`:

```gleam
import docuconf
import gleam/dict
import gleeunit
import orders/config

pub fn main() -> Nil {
  gleeunit.main()
}

fn load(env: List(#(String, String))) {
  let options =
    docuconf.options()
    |> docuconf.with_env(dict.from_list(env))
  docuconf.load_with(config.spec(), options)
}

pub fn declaration_test() {
  assert docuconf.check_declaration(config.spec()) == []
}

pub fn defaults_test() {
  let assert Ok(config) = load([#("DATABASE_URL", "postgres://u:p@db/orders")])
  assert config.port == 8080
  assert docuconf.reveal(config.database_url) == "postgres://u:p@db/orders"
}

pub fn bad_port_test() {
  let assert Error(docuconf.InvalidConfig([violation])) =
    load([#("DATABASE_URL", "postgres://db/orders"), #("PORT", "0")])
  assert violation.input == "PORT"
  assert violation.code == docuconf.OutOfRange
}

pub fn contract_is_up_to_date_test() {
  assert docuconf.check_contract(
      config.spec(),
      name: "orders",
      against: "contract.cue",
    )
    == Ok(Nil)
}
```

`check_declaration` returns the declaration's problems (an enum default
that is not one of its values, a constraint on the wrong type, a bad
name...), so a broken declaration fails `gleam test` rather than boot.

## 6. Export the contract

Add a module in `dev/` (`dev/orders/contract.gleam`), so it is not part of
your production build:

```gleam
import docuconf
import gleam/io
import orders/config

pub fn main() -> Nil {
  case
    docuconf.write_contract(config.spec(), name: "orders", to: "contract.cue")
  {
    Ok(Nil) -> io.println("wrote contract.cue")
    Error(error) -> panic as docuconf.describe(error)
  }
}
```

```sh
gleam run -m orders/contract
```

Commit `contract.cue`. The `check_contract` test above fails when the
committed file is not what the declaration exports, with a line diff. No
environment is needed to export, and none of your code runs.

`contract_with(spec, name:, package:, app_version:)` sets the CUE package
and `metadata.appVersion`.

## 7. Deploy

The platform reads `contract.cue`, not your Gleam code. Before a deploy it
checks each environment's values with `docuconf vet`, or renders the
Kubernetes env and volumes with `docuconf render`, both from the
[docuconf CLI](https://github.com/docuconf/docuconf-go). A missing
`DATABASE_URL` then fails the pipeline, not the pod. If a bad value still
reaches a pod, `load_or_exit` stops it, and `kubectl describe pod` shows
the report from the termination log.

## Using it with wisp

wisp has no configuration hook of its own, and needs none: load the
config in `main` with `load_or_exit`, before the server starts, and pass
it to your handler. [`examples/orders`](examples/orders) does exactly
this; CI builds it, runs its tests and smoke-tests the running service.

- `wisp.set_logger_level(config.log_level)`: declare the level as an
  `enum` mapping strings to `wisp.LogLevel` values.
- `wisp.log_info("config: " <> string.inspect(config))` is safe: secrets
  print redacted.
- `docuconf.enum_name(log_levels, config.log_level)` turns an enum value
  back into its string, to serve or log it.

---

# Reference

## Variables

| Builder | Contract type | Gleam value | Constraints |
|---|---|---|---|
| `string` | `string` | `String` | `min_length`, `max_length`, `pattern` |
| `int` | `int` | `Int` (64-bit range checked; ±(2^53 − 1) on JavaScript) | `min_int`, `max_int` |
| `float` | `float` | `Float` (NaN/Inf rejected) | `min_float`, `max_float` |
| `bool` | `bool` | `Bool` (`true`/`false`, any case) | |
| `duration` | `duration` (`go` encoding) | `docuconf/duration.Duration` | `min_duration`, `max_duration` |
| `duration_with(name, desc, encoding: Iso8601)` | `duration` (`go`, `iso8601`, `seconds`, `timespan`) | `docuconf/duration.Duration` | `min_duration`, `max_duration` |
| `url` | `url` | `String` | `schemes`, `max_length` |
| `enum(name, desc, [#("debug", Debug), ...])` | `enum` | your own type | |
| `string_list(name, desc, separator: ",")` | `list` (`csv`) | `List(String)` | `min_items`, `max_items`, `item_min_length`, `item_max_length` |
| `int_list(name, desc, separator: ",")` | `list` (`csv`) | `List(Int)` | `min_items`, `max_items`, `item_min`, `item_max` |
| `string_list_with(name, desc, encoding: Indexed)` | `list` (`csv`, `json`, `indexed`) | `List(String)` | `min_items`, `max_items`, `item_min_length`, `item_max_length` |
| `int_list_with(name, desc, encoding: JsonArray)` | `list` (`csv`, `json`, `indexed`) | `List(Int)` | `min_items`, `max_items`, `item_min`, `item_max` |
| `json(name, desc, decoder:, encode:)` | `json` | your own type | `schema`, `max_length` |

Every builder also takes `secret` (the value becomes a `Secret(a)`),
`details`, `group`, `examples`, `config_key`, `deprecated` and
`deploy_time_switch`.
Finish each one with `required`, `optional` (a `None` when unset) or
`default(value)`.

- **Your own types**: `map` transforms a finished variable's value, and
  `try_map` does the same with a function that can reject it. Both run only
  on a value that was read and passed its checks; a rejection is reported
  as `invalid_type` with your message:

  ```gleam
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
  ```

  For a secret variable, the message is withheld if it contains any part
  of the value.
- **Durations** are `docuconf/duration.Duration` values everywhere in
  code: `default(duration.seconds(30))`, `max_duration(duration.minutes(5))`,
  `min_remaining(duration.hours(720))`. In the environment they use the
  variable's encoding (SPEC §5): `Go` (`1m30s`), `Iso8601` (`PT90S`),
  `Seconds` (`90`, `1.5`) or `Timespan` (`[d.]hh:mm:ss[.fff]`). A Go-style
  value for an ISO 8601 variable is reported as `is not an ISO 8601
  duration such as PT30S; it looks like a Go duration...`. Contracts carry
  durations in canonical Go form (`1h30m`). For a `gleam_time` duration,
  `gleam/time/duration.nanoseconds(duration.to_nanoseconds(d))`.
- **Lists** are `Csv(separator)` (`a,b`), `JsonArray` (`["a","b"]`) or
  `Indexed` (`NAME__0=a`, `NAME__1=b`, numbered from 0 with no gap, or the
  variable is `invalid_type`). Items are never trimmed; a boot warning
  names items with spaces around them.
- **Patterns** are RE2 and match anywhere in the value; anchor them with
  `^` and `$`. Features RE2 lacks (lookaround, backreferences, atomic groups,
  possessive quantifiers) are declaration errors. Matching follows RE2 on
  both targets: `$` is end of text, and `\d`, `\w`, `\s`, `\b` are ASCII-only.
- **Integers on JavaScript** are numbers, exact only within ±(2^53 − 1).
  On that target every `int` variable exports `min` and `max` within that
  range (SPEC §5): `-9007199254740991` and `9007199254740991` unless
  `min_int`/`max_int` narrow them. Wider bounds or defaults are declaration
  errors, and a value beyond the range is `out_of_range` at boot rather
  than silently rounded. `int_list` does the same for its items through
  `itemMin` and `itemMax`. The Erlang target accepts the whole 64-bit range,
  so the same declaration can export different bounds per target; pin them
  with `min_int`/`max_int` (or `item_min`/`item_max`) if the contract must
  not depend on the target.
- **Item bounds**: `item_min` and `item_max` bound every item of an
  `int_list`, exported as `itemMin` and `itemMax`:

  ```gleam
  pub fn shards() -> docuconf.Spec(Option(List(Int))) {
    use shards <- docuconf.env(
      docuconf.int_list("SHARDS", "Shard ids this instance owns", separator: ",")
      |> docuconf.item_min(0)
      |> docuconf.item_max(1023)
      |> docuconf.optional,
    )
    docuconf.build(shards)
  }
  ```
- **Lengths** count characters, meaning Unicode code points, never bytes:
  `日本` is 2 characters and `ZÜ01` is 4. `min_length` and `max_length`
  bound a `string`; `max_length` also bounds a `url` as it is and a `json`
  value as the app receives it, before parsing and whitespace included (a
  `json` default is measured as compact JSON). `item_min_length` and
  `item_max_length` bound each item of a string list after it is split, so
  a separator never counts; they are exported as `itemMinLength` and
  `itemMaxLength`, and an `item_min_length` above `item_max_length` is a
  declaration error. A value out of bounds is `out_of_range`, and a secret
  is reported by its length, never its value.
- **Empty strings** are present values for `string` and unset for every
  other type. Values are never trimmed.
- **`json` and config files** decode into your own type with a
  `gleam/dynamic/decode` decoder. Gleam cannot derive a JSON Schema from a
  type, so you attach one with `schema` / `file_schema` (built with
  `docuconf/json`); a value the decoder rejects is `schema_mismatch`
  (`does not decode: $.currency: expected String`).
- **Splitting a declaration**: `include` declares every input of another
  spec and binds a handle to its value; `map_spec` transforms a spec's
  value.

  ```gleam
  pub fn with_cache() -> docuconf.Spec(#(Int, Cache)) {
    use port <- docuconf.env(
      docuconf.int("PORT", "HTTP listen port") |> docuconf.default(8080),
    )
    use cache <- docuconf.include(cache_spec())
    use v <- docuconf.build
    #(port(v), cache(v))
  }
  ```

Declaration problems are reported together as `InvalidDeclaration` by
`load_with`, `contract` and `check_declaration`, each naming the variable
or file: names, description length, defaults against their own constraints
(an enum default must be one of its values), secrets with defaults or
examples, non-RE2 patterns, constraints on the wrong type and the file
mount rules. `flag_warnings(spec)` lists names that look like feature flags
(SPEC §10); call it from a test or lint.

## Why `use` binds handles

In earlier, unreleased versions, `use port <- docuconf.env(...)` bound the value
itself, and the chain ended with `docuconf.succeed(Config(port:, ...))`.
To list the inputs (for export, or to report every problem at once),
docuconf ran that chain on placeholder values such as `""` and `0`. Two
things went wrong: code in the chain or in a `map` crashed on a placeholder
(`let assert Ok(u) = uri.parse("")`), and a variable declared only when
another had some value was missing from the exported contract, which the
platform then rejected at deploy.

Now each `use` binds a handle and the values only exist inside `build`:

```diff
   use port <- docuconf.env(docuconf.int("PORT", "HTTP port") |> docuconf.default(8080))
-  docuconf.succeed(Config(port:))
+  use v <- docuconf.build
+  Config(port: port(v))
```

The declaration is the same for every environment, so the contract always
lists every input, and none of your code runs until the real values are
loaded and checked. Other changes made at the same time: `secret` and
`secret_file` give a `Secret(a)`; duration bounds take `Duration` values;
`json`, `config_file` and `config_file_with` lost their `placeholder`
argument; `contract_with` takes labelled arguments; and `write_contract`
returns `WriteFailed` when it cannot write.

## Files

| Builder | Contract type | Gleam value | Options |
|---|---|---|---|
| `config_file(name, desc, path:, decoder:)` | `config` (JSON) | your type | `file_schema` |
| `config_file_with(name, desc, path:, format:, parse:, decoder:)` | `config` (YAML, TOML) | your type | `file_schema` |
| `tls(name, desc, path:)` | `tls` | `Tls(dir, cert_file, key_file, ca_file)` | `dns_names`, `key_algorithms`, `min_remaining`, `require_ca` |
| `ca_bundle(name, desc, path:)` | `caBundle` | `CaBundle(path, certificates)` | `min_certificates` |
| `keystore(name, desc, path:, format:, password_var:)` | `keystore` | path | |
| `text(name, desc, path:)` | `text` | the content | `text_pattern`, `text_min_length`, `text_max_length` |
| `binary(name, desc, path:)` | `binary` | path | |

All take `path_env`, `max_size`, `file_details`, `file_group` and `secret_file` (the value
becomes a `Secret(a)`), and are finished with `file_required` or
`file_optional`:

```gleam
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
```

`DOCUCONF_FILE_ROOT` (or `with_file_root`) is prefixed to every absolute
path, including paths read from a `path_env` variable. TLS checks use
`:public_key` on Erlang and `node:crypto` on JavaScript.

**Keystores** are opened with the password from `password_var` (an empty
password when it is `None` or unset). Neither OTP nor Node.js reads PKCS#12
or JKS, so docuconf parses the file and verifies its integrity MAC, on both
targets: PKCS#12 with SHA-1 or SHA-2 MACs (RFC 7292 key derivation and
HMAC, via `crypto` on Erlang and `node:crypto` on JavaScript), and the SHA-1
integrity digest of JKS and JCEKS stores. A match proves the password is
right and the file is intact; the keys are not decrypted. A wrong password
or a corrupted file is `keystore_unreadable`, and so are PKCS#12 files with
no MAC, PBMAC1 MACs (OpenSSL 3.4 `-pbmac1_pbkdf2`) and BER
indefinite-length encodings, which are not supported.

## Loading

| Function | Does |
|---|---|
| `load_or_exit(spec)` | the config, or the report on stderr and exit status 1 |
| `load(spec)` | `Result(a, Error)` from the process environment |
| `load_with(spec, options)` | `Result(a, Error)` with options |
| `warnings(spec, options)` | the boot warnings, without loading |

`options()` takes `with_env(dict)` (tests: the process environment is then
never read), `with_file_root`, `at_time(unix_seconds)` (certificate checks
in tests), `with_termination_log(path)`, `without_termination_log` and
`on_warning(fn(String) -> Nil)`. By default the report is written to
`DOCUCONF_TERMINATION_LOG`, else `/dev/termination-log` when it exists, cut
to 4000 bytes.

## Injected secrets

Platforms often inject secrets into the environment at runtime: Bank-Vaults'
vault-env resolves `vault:` references, `op run` resolves `op://`, and vals
resolves `ref+`. docuconf reads the environment as the process sees it after
injection, so injected values are validated like any other, and it never
resolves a reference itself (SPEC §4.5.1). If the injector did not run, a
secret variable still holds the reference; docuconf reports that as
`invalid_type`, naming the scheme but never the value:

```
  - DATABASE_URL [invalid_type]: holds an unresolved vault: reference; the injector that should resolve it did not run
```

## Contract-first mode

`docuconf/contract_first` validates an environment against a contract given
as JSON, with no Gleam declaration (SPEC §11.2 item 11): for a contract
written by hand in CUE and exported with `cue export --out json`, or one a
platform hands you. Each variable goes through the same builders and checks
as a declaration, and every list and duration encoding is read.

```gleam
let assert Ok(values) = contract_first.load(contract_json, docuconf.options())
let assert Ok(contract_first.IntValue(port)) = dict.get(values, "PORT")
```

`load` returns a `Dict(String, Value)`, with `Absent` for an unset optional
variable and `SecretValue` for a secret, or the same `InvalidConfig` error
as `load_with`. `contract_first.spec(json)` returns the declaration
instead, for `load_with` or `contract`. File inputs are not supported (a
contract with `files` is rejected), and `json` values are not checked
against their JSON Schema.

## Config-file overlays

There is no overlay API (SPEC §4.7). envoy reads the environment and
nothing layers config files in a Gleam app, so there is no file stack for a
platform-mounted overlay to sit in between the app's files and the
environment. A declaration cannot carry `overlays`, and the exported
contract never has any. Use a `config_file` input if the platform needs to
supply structured configuration.

## Not covered yet

Compared with the specification and the Elixir SDK:

- `reload: watch` is not offered; every file input is `restart`.
- JSON Schemas are not generated from types (Gleam has no reflection) and
  are not checked at boot. The decoder is the boot-time check.
- No `.env` loading, no profiles (SPEC §4.4).

## Conformance

The shared conformance suite of
[docuconf-go](https://github.com/docuconf/docuconf-go/tree/main/conformance)
(SPEC §12) runs in `gleam test` through contract-first mode
(`test/conformance_test.gleam`). It reads `cases.json` from
`DOCUCONF_CONFORMANCE`, else `../docuconf-go/conformance/cases.json`, prints
how many cases passed, were skipped and failed, and names each failure by
case id. It is skipped when the file is missing, unless
`DOCUCONF_REQUIRE_CONFORMANCE=1` (as in CI).

```sh
DOCUCONF_CONFORMANCE=../docuconf-go/conformance/cases.json DOCUCONF_REQUIRE_CONFORMANCE=1 gleam test
DOCUCONF_CONFORMANCE=../docuconf-go/conformance/cases.json DOCUCONF_REQUIRE_CONFORMANCE=1 gleam test --target javascript
```

Capability tags skipped:

| Tag | Target | Why |
|---|---|---|
| `json-schema` | both | docuconf has no JSON Schema validator; `json` values are checked by your decoder in a declaration, and not at all in contract-first mode. |
| `int64` | JavaScript only | An `Int` is a double there, exact only within ±(2^53 − 1). The Erlang target runs these cases. |

## Development

```sh
gleam test                      # Erlang
gleam test --target javascript  # Node.js
```

`test/readme_test.gleam` checks that every Gleam block in this README is
part of `test/readme_snippets.gleam` or `examples/orders`, which CI
compiles. The export test vets the generated contract with `cue vet -c`
against the meta-schema from [docuconf-go](https://github.com/docuconf/docuconf-go)
(`spec/cue`; set `DOCUCONF_SPEC_CUE`, or keep a sibling checkout). It is
skipped when `cue` is missing, unless `DOCUCONF_REQUIRE_VET=1`. TLS tests
generate certificates with `openssl`. Regenerate the golden file with
`UPDATE_GOLDEN=1 gleam test`.

Where Hex is unreachable, `scripts/offline-test.sh` runs the tests against
source checkouts of the dependencies (see the script). With wisp, mist and
their dependencies checked out too, it also builds and tests
`examples/orders`, compares its exported contract and runs its `smoke.sh`.

## Licence

MIT. See [LICENSE](LICENSE).
