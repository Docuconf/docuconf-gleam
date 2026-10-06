# docuconf for Gleam

Typed configuration contracts for Gleam applications, from the
[docuconf specification](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md) (v1alpha1).

Gleam has no macros and no reflection. Its config idiom is to read the
environment with [`envoy`](https://hexdocs.pm/envoy) and decode values with
`gleam/dynamic/decode`. docuconf follows that idiom with typed builders,
combined with `use` the way decoders are. From one declaration you get:

- a typed value for your app, or **every** problem at once, each with a
  stable error code. Secret values are never printed, and the report is also
  written to `/dev/termination-log` so `kubectl describe pod` shows it;
- boot checks for files: JSON config decoded into your own type, TLS key
  pairs (key match, expiry and `minRemaining`, DNS names, key algorithm,
  chain to `ca.crt`), CA bundles, text and binary files;
- `contract.cue`, a CUE document the platform validates before it deploys.

It runs on both targets: Erlang (OTP 27 or later) and JavaScript (Node.js).
Dependencies: `gleam_stdlib` and `envoy`.

## Example

```gleam
import docuconf
import docuconf/duration.{type Duration}
import gleam/dynamic/decode

pub type Pricing {
  Pricing(currency: String)
}

pub type Config {
  Config(
    port: Int,
    database_url: String,
    timeout: Duration,
    pricing: Pricing,
    tls: docuconf.Tls,
  )
}

pub fn spec() -> docuconf.Spec(Config) {
  use port <- docuconf.env(
    docuconf.int("PORT", "HTTP listen port")
    |> docuconf.min_int(1)
    |> docuconf.max_int(65_535)
    |> docuconf.default(8080),
  )
  use database_url <- docuconf.env(
    docuconf.url("DATABASE_URL", "Primary Postgres connection string")
    |> docuconf.schemes(["postgres"])
    |> docuconf.secret
    |> docuconf.required,
  )
  use timeout <- docuconf.env(
    docuconf.duration("CHECKOUT_TIMEOUT", "Checkout request timeout")
    |> docuconf.max_duration("1m")
    |> docuconf.default(duration.seconds(15)),
  )
  use pricing <- docuconf.file(
    docuconf.config_file(
      "pricing",
      "Pricing rules: currency and discount tiers",
      path: "/etc/orders/pricing/pricing.json",
      decoder: {
        use currency <- decode.field("currency", decode.string)
        decode.success(Pricing(currency:))
      },
      placeholder: Pricing(""),
    )
    |> docuconf.file_required,
  )
  use tls <- docuconf.file(
    docuconf.tls("serving-tls", "Certificate the API serves HTTPS with", path: "/etc/orders/tls")
    |> docuconf.dns_names(["orders.internal"])
    |> docuconf.min_remaining("720h")
    |> docuconf.file_required,
  )
  docuconf.succeed(Config(port:, database_url:, timeout:, pricing:, tls:))
}

pub fn main() {
  case docuconf.load(spec()) {
    Ok(config) -> start(config)
    Error(error) -> panic as docuconf.describe(error)
  }
}
```

A bad environment reports everything at once:

```
docuconf: 3 configuration problems:
  - DATABASE_URL [missing_required]: required, but not set
  - PORT [out_of_range]: "0" is below min 1
  - serving-tls [certificate_expiring]: certificate expires in 1366205s, less than minRemaining (2592000s)
```

### Exporting the contract

Add a module to your app and run it in CI:

```gleam
// src/orders/contract.gleam
import docuconf
import orders/config

pub fn main() {
  let assert Ok(Nil) =
    docuconf.write_contract(config.spec(), name: "orders", to: "contract.cue")
}
```

```sh
gleam run -m orders/contract
```

`contract_with(spec, name, package, app_version)` sets the CUE package and
`metadata.appVersion`.

## Variables

| Builder | Contract type | Gleam value | Constraints |
|---|---|---|---|
| `string` | `string` | `String` | `min_length`, `max_length`, `pattern` |
| `int` | `int` | `Int` (64-bit range checked; ±(2^53 − 1) on JavaScript) | `min_int`, `max_int` |
| `float` | `float` | `Float` (NaN/Inf rejected) | `min_float`, `max_float` |
| `bool` | `bool` | `Bool` (`true`/`false`, any case) | |
| `duration` | `duration` (`go` encoding) | `docuconf/duration.Duration` | `min_duration`, `max_duration` |
| `url` | `url` | `String` | `schemes` |
| `enum(name, desc, [#("debug", Debug), ...])` | `enum` | your own type | |
| `string_list(name, desc, separator: ",")` | `list` (`csv`) | `List(String)` | `min_items`, `max_items` |
| `int_list(name, desc, separator: ",")` | `list` (`csv`) | `List(Int)` | `min_items`, `max_items`, `item_min`, `item_max` |
| `json(name, desc, decoder, placeholder, encode)` | `json` | your own type | `schema` |

Every builder also takes `secret`, `group`, `examples`, `config_key`,
`deprecated` and `deploy_time_switch`. Finish each one with `required`,
`optional` (a `None` when unset) or `default(value)`.

- **Durations** use Go syntax (`1m30s`, `250ms`, `1.5h`), parsed by docuconf,
  and are written to the contract in canonical form (`1h30m`).
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
  `int_list` and are exported as `itemMin` and `itemMax`. An item outside
  them is `out_of_range`:

  ```gleam
  docuconf.int_list("SHARDS", "Shard ids this instance owns", separator: ",")
  |> docuconf.item_min(0)
  |> docuconf.item_max(1023)
  |> docuconf.optional
  ```
- **Empty strings** are present values for `string` and unset for every
  other type. Values are never trimmed.
- **`json` and config files** decode into your own type with a
  `gleam/dynamic/decode` decoder. Gleam cannot derive a JSON Schema from a
  type, so you attach one with `schema` / `file_schema` (built with
  `docuconf/json`); a value the decoder rejects is `schema_mismatch`. The
  `placeholder` is any value of the type. docuconf passes it along while it
  walks the declaration to export it or to collect every error.

Declaration problems are reported together as `InvalidDeclaration` by
`load`, `contract` and `check_declaration`. These cover names, description
length, defaults against their own constraints, secrets with defaults,
non-RE2 patterns, constraints on the wrong type and the file mount rules.
`flag_warnings(spec)` lists names that look like feature flags (SPEC §10).
Call it from a test or lint.

## Files

| Builder | Contract type | Gleam value | Options |
|---|---|---|---|
| `config_file(name, desc, path:, decoder:, placeholder:)` | `config` (JSON) | your type | `file_schema` |
| `config_file_with(..., format, parse, ...)` | `config` (YAML, TOML) | your type | `file_schema` |
| `tls(name, desc, path:)` | `tls` | `Tls(dir, cert_file, key_file, ca_file)` | `dns_names`, `key_algorithms`, `min_remaining`, `require_ca` |
| `ca_bundle(name, desc, path:)` | `caBundle` | `CaBundle(path, certificates)` | `min_certificates` |
| `keystore(name, desc, path:, format:, password_var:)` | `keystore` | path | |
| `text(name, desc, path:)` | `text` | the content | `text_pattern`, `text_min_length`, `text_max_length` |
| `binary(name, desc, path:)` | `binary` | path | |

All take `path_env`, `max_size`, `file_group` and `secret_file`, and are
finished with `file_required` or `file_optional`. `DOCUCONF_FILE_ROOT` (or
`with_file_root`) is prefixed to every absolute path, including paths read
from a `path_env` variable. TLS checks use `:public_key` on Erlang and
`node:crypto` on JavaScript.

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

`load(spec)` reads the process environment. `load_with(spec, options)`
takes `options()` with `with_env(dict)` (tests), `with_file_root`,
`at_time(unix_seconds)` (certificate checks in tests),
`with_termination_log(path)` and `without_termination_log`.

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
- No `.env` loading, no contract-first mode, no profiles (SPEC §4.4).

## Development

```sh
gleam test                      # Erlang
gleam test --target javascript  # Node.js
```

The export test vets the generated contract with `cue vet -c` against the
meta-schema from [docuconf-go](https://github.com/docuconf/docuconf-go)
(`spec/cue`; set `DOCUCONF_SPEC_CUE`, or keep a sibling checkout). It is
skipped when `cue` is missing, unless `DOCUCONF_REQUIRE_VET=1`. TLS tests
generate certificates with `openssl`. Regenerate the golden file with
`UPDATE_GOLDEN=1 gleam test`.

Where Hex is unreachable, `scripts/offline-test.sh` runs the tests against
source checkouts of the dependencies (see the script).

## Licence

MIT. See [LICENSE](LICENSE).
