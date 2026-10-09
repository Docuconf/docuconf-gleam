# orders: a docuconf example

A small HTTP service built with [wisp](https://hexdocs.pm/wisp) on
[mist](https://hexdocs.pm/mist). Its configuration is declared once, in
[`src/orders/config.gleam`](src/orders/config.gleam), with the docuconf
builders. That one declaration:

- loads and checks the environment at startup, and reports every problem at
  once with a stable error code, never printing the secret;
- gives the app typed values: an `Int` port, a `wisp.LogLevel`, a
  `List(String)` of origins, a `Duration` timeout, and the database URL as
  a `docuconf.Secret`, which prints redacted in logs;
- exports [`contract.cue`](contract.cue), which the platform validates
  before it deploys.

| Variable | Type | Rules |
|---|---|---|
| `PORT` | int | 1–65535, default `8080` |
| `LOG_LEVEL` | enum | `debug`, `info`, `warn`, `error`; default `info` |
| `DATABASE_URL` | url | secret, required, scheme `postgres`, at most 2048 characters |
| `ALLOWED_ORIGINS` | list of strings (comma-separated) | at least 1 item; default `http://localhost:3000` |
| `REQUEST_TIMEOUT` | duration (`30s`, `1m30s`) | 1s–5m, default `30s` |
| `WORKER_COUNT` | int | 1–64, default `4` |
| `WEBHOOK_KEYS` | key set (comma-separated) | always secret, optional; 1–2 keys of 32–256 characters each |

## Run it

With Gleam and Erlang/OTP 27 or later, from this directory:

```sh
DATABASE_URL=postgres://orders:secret@localhost:5432/orders gleam run
```

```sh
curl localhost:8080/healthz   # ok
curl localhost:8080/config    # the typed values, with "database_url":"***" and "webhook_keys":"***"
```

The example depends on the SDK in this repository
(`docuconf_gleam = { path = "../.." }` in `gleam.toml`), not on a published
version.

## A bad environment

`main` loads the configuration with `docuconf.load_or_exit`. With `PORT=0`
and no `DATABASE_URL`, the service does not start. It exits with status 1
and prints, after Gleam's own build lines, with no stack trace:

```
$ PORT=0 gleam run
docuconf: 2 configuration problems:
  - DATABASE_URL [missing_required]: required, but not set
  - PORT [out_of_range]: "0" is below min 1
```

In Kubernetes the same report also goes to `/dev/termination-log`, so
`kubectl describe pod` shows it.

[`smoke.sh`](smoke.sh) checks both cases: it starts the service, calls
`/healthz` and `/config`, checks the startup log does not leak the secret,
then starts it with the bad environment. It also posts webhooks signed with
each key of the key set below.

## Rotate a key

`WEBHOOK_KEYS` is a `keySet` (`docuconf.key_set`): `POST /webhooks/payments`
accepts a body whose `X-Signature` header is the hex HMAC-SHA256 of the body
under any key in the set. [`src/orders/webhook.gleam`](src/orders/webhook.gleam)
checks it with `docuconf.any_key`, which tries every key without stopping at
the first match, so the time taken does not say which key matched. A variable is
read once, at start, so a new key reaches the service only when the pods
restart; with two keys valid at once, no webhook is turned away while that
happens:

1. Add the new key as the second item (`old,new` in the Secret), and roll out.
2. Switch the sender to the new key.
3. Remove the old key (`new`), and roll out.

In the platform's values, the key set is a reference to one Secret key that
holds `old,new` while rotating:

```yaml
WEBHOOK_KEYS:
  secretKeyRef: {name: orders-webhooks, key: keys}
```

The contract allows 1 or 2 keys of 32 to 256 characters each, so a trailing
comma or a truncated key stops the service at boot instead of locking out
the sender, and the problem never prints a key:

```
$ DATABASE_URL=postgres://orders:secret@localhost:5432/orders WEBHOOK_KEYS=old-webhook-key-0123456789abcdef0123, gleam run
docuconf: 1 configuration problem:
  - WEBHOOK_KEYS [out_of_range]: key 2 is empty (a stray separator?)
```

The generated docs print these steps for every key set, so the declaration's
`details` do not repeat them.
[`test/webhook_test.gleam`](test/webhook_test.gleam) walks through a
rotation.
[docuconf-go's SPEC section 6.1](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md#61-rotation)
covers rotation in general.

## Test the configuration

```sh
gleam test
```

[`test/orders_test.gleam`](test/orders_test.gleam) loads the declaration
from a map with `docuconf.with_env`, without touching the process
environment, and checks that the committed `contract.cue` is what the
declaration exports (`docuconf.check_contract`).

## Export the contract

```sh
gleam run -m orders/contract
```

This writes `contract.cue` from the declaration
([`dev/orders/contract.gleam`](dev/orders/contract.gleam); `dev/` keeps it
out of the production build). Never edit it by hand: `gleam test` fails if
it differs from what the declaration exports.

## Generated docs

[`CONFIG.md`](CONFIG.md), [`CONFIG.agents.md`](CONFIG.agents.md) and
[`docs.json`](docs.json) are generated from `contract.cue` by the `docuconf`
CLI from [docuconf-go](https://github.com/docuconf/docuconf-go); never edit
them by hand either. The first is the reference for developers, the second
the rules and facts AI agents need to change the code or set deployment
values, and the third the docs model both are rendered from. Regenerate them
after exporting the contract:

```sh
docuconf docs contract.cue -o CONFIG.md
docuconf docs contract.cue --format agents -o CONFIG.agents.md
docuconf docs contract.cue --format model -o docs.json
```

CI runs the same commands with `--check` and fails when a file is out of
date. `REQUEST_TIMEOUT` shows where the text comes from: its description is
the declaration's second argument, and `docuconf.details` adds its details.

## Deploy

The platform team never reads the Gleam code. Before a deploy, it checks the
values for each environment against `contract.cue` with `docuconf vet`, or
renders the Kubernetes env and volumes with `docuconf render`, both from the
[docuconf CLI](https://github.com/docuconf/docuconf-go). A Helm user gets the
same checks from the [docuconf Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm).
A missing `DATABASE_URL` or an out-of-range `PORT` then fails the pipeline,
not the pod.
