# maludb-realtimed

V3-REALTIME-01 — SSE gateway over `malu$event`.

`maludb-realtimed` is a stdlib-Python service that streams events from
`maludb_core.malu$event` to authenticated clients over SSE. It uses
`LISTEN maludb_event` for low-latency wakeups and falls back to a
configurable poll interval. Every connection is bound to the verified
token's account via the `maludb_core.current_account_id` GUC, so RLS
hides cross-tenant events naturally.

## Endpoints

- `GET /healthz` — liveness, no auth.
- `GET /events?subscription=<id>` — SSE stream, `Authorization: Bearer <token>`.
- `POST /events/ack` — `{"subscription_id":N,"through_event_id":M}`,
  same auth, advances the subscription's persistent cursor and
  records `malu$event_delivery` rows.

## Run

```bash
export MALUDB_REALTIMED_DB=maludb
maludb-realtimed --host 127.0.0.1 --port 5332
```

Env vars: `MALUDB_REALTIMED_DB` (required), `_HOST`, `_PORT`, `_USER`,
`_PASSWORD`, `_POLL_S` (default 1.0), `_BATCH` (default 100).

## Replay

Subscriptions persist their `cursor` in `malu$event_subscription`.
Reconnecting clients get every event past their cursor in a single
initial drain before the live stream attaches. `POST /events/ack`
advances the cursor; the client controls how often it acks.

## Smoke test

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
cd services/maludb-realtimed
PYTHONPATH=src python3 -m pytest tests/
```
