# V3-OPS-01 — operator sample configs

Reference configs for the two operational front-ends MaluDB
operators typically put in front of a PostgreSQL cluster:

| File | Role |
|---|---|
| [`pgbouncer.ini`](pgbouncer.ini) | Connection pooler — `pool_mode = transaction`, sized for MaluDB's mix of short-lived REST/MC2DB calls and long-lived realtime LISTEN sessions. |
| [`haproxy.cfg`](haproxy.cfg) | TCP load balancer — one frontend for writes (primary only) and one for reads (any replica), keyed off the standard `pg_isready` / `pg_stat_replication` probes. |

These are **starting points**, not turn-key production drops.
Read [`docs/v3/read-replicas.md`](../read-replicas.md) first; the
routing matrix there is what these configs encode. Tune the pool
sizes, timeouts, and `server_check_query`/health probes to your
workload before deploying.

## Use cases the samples cover

### Single PgBouncer in front of one PostgreSQL primary

The simplest deployment. PgBouncer terminates the application's
long-lived connections and reuses a small pool of upstream
PostgreSQL connections. `pool_mode = transaction` keeps the
upstream count low; **prepared statements must be off** at the
client (psycopg `prepare_threshold=None`, `libpq` defaults are OK)
because PgBouncer rotates upstream connections between
transactions.

### HAProxy + primary + replicas

Two HAProxy frontends:

* `:5432` → only the current primary, identified by
  `pg_is_in_recovery() = false`. Writes go here.
* `:5433` → any replica (or primary as last-resort fallback).
  Reads go here.

The MaluDB realtime SSE / WebSocket sessions live on long-lived
LISTEN connections — those must route to the **primary** because
LISTEN/NOTIFY does not propagate to replicas. The samples reflect
that constraint with the right `option tcp-check` body.

## What's intentionally NOT in here

* **Failover**. HAProxy's health check picks the *current* primary
  but does not promote one — operators are expected to run a real
  HA stack (Patroni, repmgr, Stolon) on top, or accept manual
  promotion. The sample is a routing layer, not an HA controller.
* **TLS termination**. The sample assumes you put TLS termination
  at the HAProxy edge (or directly on PostgreSQL with `ssl=on`).
  Adding the right `bind ... ssl crt /etc/...` lines is a one-liner
  but operator-specific.
* **PgBouncer auth integration with maludb_secret_consumer**.
  Until V3-AUTH-03 lands an asymmetric JWT verifier, PgBouncer's
  `auth_query` works fine against MaluDB role accounts; we just
  don't recommend wiring it to the V3-AUTH-01 token catalog
  directly.

## Test plan

Both files are validated only structurally (`pgbouncer
-V /dev/null`-style syntax check after envsubst). End-to-end traffic
testing is an operator concern — the configs are meant to be a
known-good starting point, not a guaranteed-working drop-in.
