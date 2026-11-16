# shop: a docuconf example

One small program with two roles, a web server and a queue worker, that
shows three parts of the [docuconf spec](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md)
end to end:

- **roles** (SPEC §4.9): `DOCUCONF_ROLE` says which role this workload runs,
  and an input only the other role uses is not required;
- **requiredIf** (SPEC §4.2.1): `LOG_SCHEMA_URL` is required when
  `LOG_FORMAT` is `json`, and the webhook signing key file when
  `WEBHOOKS_ENABLED` is true;
- an **included fragment** (SPEC §4.8): the contract includes `otel@1`, so
  the OpenTelemetry variables are checked at boot like any other.

There is no real server, database or queue. The shop loads its
configuration, prints one line saying what it would run, and exits 0; on a
bad environment it prints every problem and exits 1.

## The contract

The Gleam declaration builders do not declare roles, `requiredIf` or
includes, so the shop is **contract-first**: [`contract.json`](contract.json)
is the contract, written by hand, and
[`src/shop/config.gleam`](src/shop/config.gleam) loads it at startup with
`docuconf/contract_first` and turns the checked values into a typed
`Config`. The queues the worker prints come from that `Config`, not from the
raw environment.

| Input | Type | Rules |
|---|---|---|
| `DOCUCONF_ROLE` | enum | required; `web` or `worker` |
| `DATABASE_URL` | url | required, secret; scheme `postgres` or `postgresql` |
| `PORT` | int | web only; 1–65535, default `8080` |
| `ALLOWED_ORIGINS` | list of strings (comma-separated) | web only; required |
| `QUEUES` | list of strings (comma-separated) | worker only; required |
| `WEBHOOKS_ENABLED` | bool | worker only; default `false` |
| `LOG_FORMAT` | enum | `text` or `json`; default `text` |
| `LOG_SCHEMA_URL` | url | scheme `https`; required when `LOG_FORMAT` is `json` |
| `OTEL_*` | from `otel@1` | twelve optional variables, such as `OTEL_EXPORTER_OTLP_PROTOCOL` (`grpc`, `http/protobuf`, `http/json`) |
| file `webhook-signing-key` | text | worker only; secret, at `/etc/shop/webhooks/signing.key`, at least 32 characters; required when `WEBHOOKS_ENABLED` is true |

[`contract.cue`](contract.cue) is the same contract in CUE, for `cue vet` and
`docuconf docs`. [`contract-cue.sh`](contract-cue.sh) writes it from
`contract.json` (it needs `cue`); never edit it by hand:

```sh
./contract-cue.sh
```

## Run it

With Gleam, and Erlang/OTP 27 or later or Node.js, from this directory (the
shop reads `contract.json` from the directory it runs in):

```sh
DOCUCONF_ROLE=web DATABASE_URL=postgres://shop@db:5432/shop ALLOWED_ORIGINS=https://shop.example gleam run
# shop web: port 8080, origins https://shop.example

DOCUCONF_ROLE=worker DATABASE_URL=postgres://shop@db:5432/shop QUEUES=default,mail gleam run
# shop worker: queues default,mail, webhooks off
```

Add `--target javascript` to run it on Node.js. With `WEBHOOKS_ENABLED=true`
the worker also needs the key file; `DOCUCONF_FILE_ROOT` is prefixed to its
path, so a local run can keep it in a directory of its own:

```sh
mkdir -p files/etc/shop/webhooks
openssl rand -hex 32 > files/etc/shop/webhooks/signing.key
DOCUCONF_ROLE=worker DATABASE_URL=postgres://shop@db:5432/shop QUEUES=default,mail \
  WEBHOOKS_ENABLED=true DOCUCONF_FILE_ROOT=files gleam run
# shop worker: queues default,mail, webhooks on
```

A bad environment stops it with status 1, every problem listed with its
code, and the database URL never printed:

```
$ DOCUCONF_ROLE=worker DATABASE_URL=postgres://shop@db:5432/shop QUEUES=default LOG_FORMAT=json gleam run
docuconf: 1 configuration problem:
  - LOG_SCHEMA_URL [missing_required]: is required when LOG_FORMAT is "json"
```

## The test matrix

[`test/shop_test.gleam`](test/shop_test.gleam) loads the contract for each
case with `docuconf.with_env`, from the base environment
`DATABASE_URL=postgres://shop@db:5432/shop` and a fresh, empty
`DOCUCONF_FILE_ROOT`:

| # | Environment (plus the base) | Result |
|---|---|---|
| 1 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example` | ok: `shop web: port 8080, origins https://shop.example` |
| 2 | `DOCUCONF_ROLE=worker QUEUES=default,mail` | ok: `shop worker: queues default,mail, webhooks off`; the worker needs no `ALLOWED_ORIGINS` |
| 3 | `DOCUCONF_ROLE=web` | `ALLOWED_ORIGINS [missing_required]` |
| 4 | `QUEUES=default` (no role) | `DOCUCONF_ROLE [missing_required]`, and nothing else |
| 5 | `DOCUCONF_ROLE=cron` | `DOCUCONF_ROLE [not_in_enum]`, and nothing else |
| 6 | `DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json` | `LOG_SCHEMA_URL [missing_required]: is required when LOG_FORMAT is "json"` |
| 7 | as 6, plus `LOG_SCHEMA_URL=https://logs.example/v1.json` | ok |
| 8 | `DOCUCONF_ROLE=worker QUEUES=default WEBHOOKS_ENABLED=true`, no key file | `webhook-signing-key [file_missing]`: `<root>/etc/shop/webhooks/signing.key not found, and is required when WEBHOOKS_ENABLED is true` |
| 9 | as 8, with a key of 32 or more characters at that path | ok: `shop worker: queues default, webhooks on` |
| 10 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example WEBHOOKS_ENABLED=true` | ok: the key file belongs to the worker |
| 11 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example OTEL_EXPORTER_OTLP_PROTOCOL=carrier-pigeon` | `OTEL_EXPORTER_OTLP_PROTOCOL [not_in_enum]`: the fragment's variables are checked at boot |

```sh
gleam test                      # Erlang
gleam test --target javascript  # Node.js
```

[`smoke.sh`](smoke.sh) runs the shop as a real process for cases 1, 2 and 6
and checks its output and exit status (`SHOP_TARGET=javascript ./smoke.sh`
for Node.js).

## Generated docs

[`CONFIG.md`](CONFIG.md), [`CONFIG.agents.md`](CONFIG.agents.md) and
[`docs.json`](docs.json) are generated from `contract.cue` by the `docuconf`
CLI from [docuconf-go](https://github.com/docuconf/docuconf-go); never edit
them by hand. Regenerate them after changing the contract:

```sh
docuconf docs contract.cue -o CONFIG.md
docuconf docs contract.cue --format agents -o CONFIG.agents.md
docuconf docs contract.cue --format model -o docs.json
```

CI runs the same commands with `--check`, on both targets runs the tests and
`smoke.sh`, checks that `contract.cue` is what `contract-cue.sh` writes, and
vets it with `cue vet -c` against the meta-schema.
