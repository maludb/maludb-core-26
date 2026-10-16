# maludb-restd

V3-API-01 — curated REST gateway over the MaluDB memory model.

`maludb-restd` is a stdlib-Python HTTP service that reads
`maludb_core.malu$rest_endpoint` and dispatches incoming HTTPS requests
to the registered SQL/PL/pgSQL handler functions under the
authenticated account's role. Every request lands a row in
`malu$rest_invocation`.

## What's in the first cut (v0.1.0)

- Built-in routes — `/healthz`, `/version`, `/openapi.json`.
- Catalog-driven dispatch — `GET / POST / PUT / PATCH / DELETE`
  against any `(method, path)` registered with
  `maludb_core.rest_register_endpoint(...)`.
- Bearer-token authentication via `maludb_core.auth_token_verify(...)`
  (V3-AUTH-01). Required-scope check before dispatch.
- Tenant binding by `maludb_core.current_account_id` GUC, set per
  request from the verified token's account_id.
- Append-only audit through `maludb_core.rest_log_invocation(...)`.

## Not yet (Stage 10 follow-ups)

- TLS (the listener is HTTP-only in v0.1.0; deploy behind a
  TLS-terminating proxy or wait for V3-API-01b's TLS path).
- Request-body binding to handler arguments. The first cut treats
  every registered handler as zero-arg; the curated catalog of
  stable endpoints with typed parameters lands in V3-API-01b's
  follow-up.
- JWT signature verification (waits on the V3-AUTH-01 C verifier).
- The full curated REST catalog (~20 endpoints listed in
  `version3-plan.md` V3-API-01) — only the three built-in routes
  are populated automatically.

## Install

```bash
pip install -e services/maludb-restd[test]
```

## Run

```bash
export MALUDB_RESTD_DB=maludb
export MALUDB_RESTD_HOST=/var/run/postgresql   # or a TCP host
maludb-restd --host 127.0.0.1 --port 5331
```

Env vars: `MALUDB_RESTD_DB` (required), `MALUDB_RESTD_HOST`,
`MALUDB_RESTD_PORT`, `MALUDB_RESTD_USER`, `MALUDB_RESTD_PASSWORD`.

The listening role should be granted `maludb_rest_dispatcher`
(NOLOGIN, created by migration `0.43.0 → 0.44.0`) so the daemon can
write to `malu$rest_invocation`. Per request, the daemon binds the
tenant GUC, NOT the role — production deployments that need full
RLS-aware role switching should configure `SET ROLE` policy via the
endpoint's `handler_function` body.

## Smoke test

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
cd services/maludb-restd
PYTHONPATH=src python3 -m pytest tests/
```

Tests run against the live `contrib_regression` database that
`make installcheck` populates; they create two `/test/*` endpoint
rows, drive the daemon, and assert the audit rows landed.

## Audit contract

Every request — including 401/404/500 paths — writes a row in
`malu$rest_invocation` with:

- `call_id uuid` (PK)
- `endpoint_id` (NULL for 404s)
- `account_id`, `token_id` (populated when the token verifies)
- `method`, `path`, `source_ip`
- `request_hash`, `response_hash` (SHA-256 of body bytes)
- `status_code`, `latency_ms`
- `success boolean`, `error_code`, `error_message`

The built-in routes (`/healthz`, `/version`, `/openapi.json`) do NOT
audit — they're operator-facing liveness/metadata. V3-OBS-01 will
expose them as Prometheus counters instead.
