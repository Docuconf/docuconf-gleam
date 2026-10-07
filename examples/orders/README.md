# orders: a docuconf example

A small HTTP service built with [wisp](https://hexdocs.pm/wisp) on
[mist](https://hexdocs.pm/mist). Its configuration is declared once, in
[`src/orders/config.gleam`](src/orders/config.gleam), with the docuconf
builders. That one declaration:

- loads and checks the environment at startup, and reports every problem at
  once with a stable error code, never printing the secret;
- gives the app typed values: an `Int` port, a `wisp.LogLevel`, a
  `List(String)` of origins, a `Duration` timeout;
- exports [`contract.cue`](contract.cue), which the platform validates
  before it deploys.

| Variable | Type | Rules |
|---|---|---|
| `PORT` | int | 1–65535, default `8080` |
| `LOG_LEVEL` | enum | `debug`, `info`, `warn`, `error`; default `info` |
| `DATABASE_URL` | url | secret, required, scheme `postgres` |
| `ALLOWED_ORIGINS` | list of strings (comma-separated) | at least 1 item; default `http://localhost:3000` |
| `REQUEST_TIMEOUT` | duration (`30s`, `1m30s`) | 1s–5m, default `30s` |
| `WORKER_COUNT` | int | 1–64, default `4` |

## Run it

With Gleam and Erlang/OTP 27 or later, from this directory:

```sh
DATABASE_URL=postgres://orders:secret@localhost:5432/orders gleam run
```

```sh
curl localhost:8080/healthz   # ok
curl localhost:8080/config    # the typed values, with "database_url":"***"
```

The example depends on the SDK in this repository (`docuconf = { path = "../.." }`
in `gleam.toml`), not on a published version.

## A bad environment

With `PORT=0` and no `DATABASE_URL`, the service does not start. It exits
with status 1 and prints, after Gleam's own build lines:

```
$ PORT=0 gleam run
docuconf: 2 configuration problems:
  - DATABASE_URL [missing_required]: required, but not set
  - PORT [out_of_range]: "0" is below min 1
```

In Kubernetes the same report also goes to `/dev/termination-log`, so
`kubectl describe pod` shows it.

[`smoke.sh`](smoke.sh) checks both cases: it starts the service, calls
`/healthz` and `/config`, then starts it with the bad environment.

## Export the contract

```sh
gleam run -m orders/contract
```

This writes `contract.cue` from the declaration
([`src/orders/contract.gleam`](src/orders/contract.gleam)). Never edit it by
hand: CI exports it again and fails if it differs from the committed file.

## Deploy

The platform team never reads the Gleam code. Before a deploy, it checks the
values for each environment against `contract.cue` with `docuconf vet`, or
renders the Kubernetes env and volumes with `docuconf render`, both from the
[docuconf CLI](https://github.com/docuconf/docuconf-go). A Helm user gets the
same checks from the [docuconf Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm).
A missing `DATABASE_URL` or an out-of-range `PORT` then fails the pipeline,
not the pod.
