# V3-CRON-02 / V3-QUEUE-02 — pgmq + pg_cron adoption decision

**Stage**: v3.1 Stage L
**Date**: 2026-05-14
**Status**: **Decision recorded. No code change in v3.1.**

`maludb_core--0.44.0--0.45.0.sql` (V3-QUEUE-01) and
`maludb_core--0.45.0--0.46.0.sql` (V3-CRON-01) both shipped with an
explicit "door left open" for swapping the native implementation
for `pgmq` and `pg_cron` respectively. This document closes that
follow-up by recording the v3.1 adoption decision.

## TL;DR

| Component | Decision | Why |
|---|---|---|
| `pg_cron` | **Optional tick driver — adopted in docs, not in code** | Available in PGDG; the canonical V3-CRON-01 scheduler stays the user-facing surface and just exposes `schedule_tick()` for `pg_cron` to call once a minute. Operators who can't run `pg_cron` keep using a systemd timer or a one-line `psql` loop. |
| `pgmq` | **Deferred indefinitely** | Not available in PGDG (no `.deb`); requires source build + module load on every self-hosted cluster. The V3-QUEUE-01 native implementation already has DLQ + visibility leases + idempotency keys + DEAD status — every shape `pgmq` provides. The performance ceiling we're nowhere near. |

This is a v3.1 / GA decision. We will revisit `pgmq` once one of:
- We hit a queue throughput wall (>10k enqueue/s sustained against
  V3-QUEUE-01) under a real workload, or
- `pgmq` lands in PGDG as `postgresql-N-pgmq`.

## Context

### What V3-QUEUE-01 ships today

Three tables — `malu$queue`, `malu$queue_job`, `malu$queue_lease` —
plus the public surface:

- `queue_register(name, visibility_timeout_ms, max_retries, dlq?)`
- `queue_enqueue(name, payload, idempotency_key?, priority?, visible_at?, account_id?)`
- `queue_lease(name, worker_id, max_jobs)` — `FOR UPDATE SKIP LOCKED`
- `queue_complete(job_id, result?)`, `queue_fail(job_id, error)`,
  `queue_reap_expired_leases()`

Atomic, tenant-scoped (RLS on owner_schema), idempotency-keyed,
DLQ-routed on max-retries.

### What V3-CRON-01 ships today

- `malu$schedule` rows (cron-expr OR @aliases)
- `schedule_register(name, cron_expr, action_kind, action_payload)`
  with `action_kind ∈ {enqueue, sql, function}`
- `schedule_run_now(name)` — manual fire
- `schedule_tick()` — picks all due schedules and runs their actions

The scheduler is **passive**: it doesn't spin its own background
worker; an external tick driver calls `schedule_tick()` (systemd
timer, `pg_cron`, or a `psql` one-liner).

### What `pg_cron` provides

`pg_cron 1.6.7` ships in PGDG (`postgresql-17-cron`). It is a
PostgreSQL extension that runs cron jobs from inside the cluster.

**Shape**:
- One `cron.job` row per schedule.
- A background worker (single, per cluster) wakes up every minute,
  picks due jobs, runs them as the configured database role.
- All jobs run inside one configured database (`cron.database_name`,
  default `postgres`). Cross-database scheduling exists but is
  awkward.

**License**: PostgreSQL License — compatible.

### What `pgmq` provides

`pgmq` (Tembo, 2023+) is a SQL-native message queue extension.

**Shape**:
- `pgmq.send`, `pgmq.read`, `pgmq.delete`, `pgmq.archive` —
  similar lease-based semantics to V3-QUEUE-01.
- Per-queue tables with auto-VACUUM tuning.
- Archive tables for completed messages.

**Availability**: **Not in PGDG.** Self-hosters have to build from
source (`make`/`make install` against the `pgmq` repo) or use Tembo's
docker images. License: PostgreSQL License — compatible.

## Comparison matrix

| Property | V3-QUEUE-01 (native) | `pgmq` |
|---|---|---|
| Available in PGDG | ✅ shipped as part of `maludb_core` | ❌ source build |
| DLQ | ✅ `malu$queue.dead_letter_queue` | ✅ via archive + filter |
| Visibility leases | ✅ `queue_lease` + `expires_at` | ✅ visibility_timeout |
| Idempotency keys | ✅ `UNIQUE (queue_id, idempotency_key)` | ❌ message-id only |
| Tenant-scoped (RLS) | ✅ `owner_schema` | ⚠ table-per-queue; tenant isolation has to be designed on top |
| Priority queues | ✅ `priority` column, ORDER BY | ❌ |
| Future-visible jobs | ✅ `visible_at` | ✅ `vt` |
| FOR UPDATE SKIP LOCKED | ✅ | ✅ |
| Archive of completed | ⚠ `queue_history` partition (optional) | ✅ first-class |
| Maturity | New in v3.0 | New (2023+) |

**Verdict**: The two have functional parity for our needs.
V3-QUEUE-01 wins on idempotency keys and tenant scoping; `pgmq`
wins on archive-by-default. Neither difference is decisive.

| Property | V3-CRON-01 (native) | `pg_cron` |
|---|---|---|
| Available in PGDG | ✅ part of `maludb_core` | ✅ `postgresql-17-cron` 1.6.7 |
| Tenant-scoped | ✅ schedules per `owner_schema` | ⚠ one cluster-wide role / DB |
| Cron syntax | ✅ 5-field + @aliases | ✅ 5-field + @aliases |
| Tick driver | external (caller-supplied) | internal background worker |
| Cross-database | n/a | awkward (requires `dblink`) |
| Maturity | New in v3.0 | Mature (Citus, since 2016) |

**Verdict**: `pg_cron`'s only meaningful advantage is the built-in
tick driver. V3-CRON-01's tenant-scoping is a genuine feature we
don't want to lose.

## Decision

### `pg_cron` — adopt as an *optional* tick driver

The recommended self-host wiring is:

```sql
-- Once, by maludb_memory_admin:
ALTER SYSTEM SET shared_preload_libraries = pgaudit, pg_stat_statements, pg_cron;
ALTER SYSTEM SET cron.database_name        = <db>;
-- restart, then:
CREATE EXTENSION pg_cron;
SELECT cron.schedule('maludb_schedule_tick', '* * * * *',
                     $$SELECT maludb_core.schedule_tick();$$);
```

That's it. V3-CRON-01's surface stays unchanged — operators
register schedules through `schedule_register(...)`, not through
`cron.schedule`. We pay `pg_cron` only for the once-a-minute tick,
which it does well.

Operators who can't install `pg_cron` (managed PostgreSQL providers
that pin extensions, or stripped-down environments) keep using a
systemd timer:

```ini
# /etc/systemd/system/maludb-tick.timer
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=maludb-tick.service
```

```ini
# /etc/systemd/system/maludb-tick.service
[Service]
Type=oneshot
ExecStart=/usr/bin/psql -At -c "SELECT maludb_core.schedule_tick();"
```

The wiring is documented in `docs/admin-guide.md` (added alongside
this decision) so this isn't ambiguous in production.

### `pgmq` — defer

No adoption work in v3.1. Reasons:

1. **No PGDG package**. Every self-hosted MaluDB cluster would need
   to build `pgmq` from source as part of the install path, adding
   complexity to `scripts/maludb-bootstrap` and the fresh-VM field
   test (`docs/v3/field-test-fresh-vm-copypaste.md`).
2. **Functional parity with V3-QUEUE-01**. The only meaningful
   gap (archive-by-default) is a one-migration cleanup if we ever
   want it.
3. **We lose RLS-scoped tenancy**. V3-QUEUE-01 puts every queue row
   in `malu$queue_job` with `owner_schema` — RLS does the rest.
   `pgmq` makes one Postgres table per queue, which is awkward to
   tenant-scope without re-creating queues per tenant.
4. **Performance is not the bottleneck**. Real MaluDB workloads
   (ingestion, embedding, lifecycle sweeps, ANN rebuild) are
   write-amplified by the actual model calls, not by queue
   transport. V3-QUEUE-01's `FOR UPDATE SKIP LOCKED` path is
   measured in microseconds.

If/when we revisit, the swap path is small: replace the V3-QUEUE-01
body of `queue_enqueue` / `queue_lease` / etc. with `pgmq.send` /
`pgmq.read` calls behind the same SQL signature. The migration
chain doesn't need to change shape.

## Tickets opened

None at v3.1. The follow-ups become:

- `V3-QUEUE-03` (future, conditional): Adopt `pgmq` if/when it
  lands in PGDG OR we hit a throughput wall. Acceptance criterion:
  `pgmq` runs the same V3-QUEUE-01 contract tests unchanged.
- `V3-CRON-03` (future, conditional): Replace the systemd-timer
  fallback with a `pg_cron`-only path once PGDG `postgresql-17-cron`
  is universally available in the deployments we care about.

## Operator action required

None for v3.1. Self-hosters running V3-CRON-01 schedules today
should optionally adopt the `pg_cron` tick driver per the
recommended wiring above — purely a convenience, not a requirement.
