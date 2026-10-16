# V3-REPL-01 — Read Replica Support Statement

MaluDB supports **PostgreSQL physical streaming replicas** for
read-heavy retrieval and analytics workloads. Managed multi-region
replica orchestration is **not** part of V3; this document records
the supported deployment shape and the routing rules that operators
MUST follow to keep the consistency contract intact.

## What's supported in V3

Sample configs for the front-end load balancer and connection pooler
live in [`docs/v3/samples/`](samples/):

* [`samples/pgbouncer.ini`](samples/pgbouncer.ini) — transaction-mode
  pool tuned for MaluDB's REST + MC2DB workload.
* [`samples/haproxy.cfg`](samples/haproxy.cfg) — two TCP frontends
  (`:5432` writes/LISTEN to primary; `:5433` reads to any replica).

A standard PostgreSQL primary + N physical streaming replicas, set up
with the usual machinery:

```
postgresql.conf
  wal_level = replica          # or 'logical' if you also want logical decoding
  max_wal_senders = 10
  archive_mode = on
  archive_command = '...'      # WAL archive for V3-BACKUP-01 PITR

# Replica recovery.signal
primary_conninfo  = 'host=primary user=replicator ...'
primary_slot_name = 'maludb_replica_<N>'
restore_command   = '...'
```

A single replication user (`replicator`) per replica with the
`REPLICATION` attribute. One physical replication slot per replica
on the primary so unconsumed WAL doesn't accumulate.

## What MUST go to the primary

Every write surface in MaluDB. Read-only routing MUST refuse these:

| Surface | Why |
|---|---|
| `register_*` / `submit_request` / `node_submit` etc. | Multi-model atomic writes. |
| `queue_enqueue` / `queue_lease` / `queue_ack` / `queue_nack` | Queue lease semantics require primary. |
| `schedule_*` / `schedule_tick` | Run history + next_run_at updates. |
| `emit_event` / `event_ack` | Append-only event log + cursor advance. |
| `auth_token_*` / `secret_*` | Audit + RLS-sensitive writes. |
| `source_object_register` / `source_object_promote_to_source_package` | Verbatim archive + Derivation Ledger writes. |
| `embedding_enqueue` / `embedding_record_output` | Job + output catalog writes. |
| `retrieve_with_envelope` | Writes `malu$retrieval_envelope` + decision audit. |
| `vector_index_record` / `ann_rebuild` | Index status writes. |
| `log_drain_*` / `backup_*` / `preview_env_*` | Stage 15 catalog writes. |
| MC2DB `tools/call` of any non-read_only risk_class | Invocation audit row. |
| REST any non-`GET` request | Invocation audit row. |
| Realtime `POST /events/ack` | Subscription cursor advance. |

## What MAY route to a replica

Read-only retrieval and analytics paths:

| Surface | Notes |
|---|---|
| `execute_retrieval` / `retrieve` SETOF readers | Tolerate small lag; the temporal-mode query semantics still hold against the replica's snapshot. |
| `search_memory_exact` / `search_memory_filter` | Vector compartment reads. |
| `vector_index_status()` | Operator visibility. |
| `metrics_prometheus_scrape()` | Approximate snapshot; OK for /metrics. |
| `event_fetch_batch` | Idempotent SELECT past a cursor — but ack stays on primary. |
| `queue_stats` | Approximate snapshot. |
| `schedule_list` | Read-only metadata. |
| `secret_get_metadata` | Metadata only, no decryption. |

## Routing implementation

V3 does not ship a built-in router. Two pragmatic options:

- **PgBouncer with two pools** — one pointing at the primary (`maludb_primary`), one at a replica (`maludb_replica`). Application-side: route writes to `maludb_primary`, GET-only REST endpoints to `maludb_replica`.
- **HAProxy front for HTTPS** — `maludb-restd` and `maludb-realtimed` both listen on the same port; the load balancer steers paths by verb. Writes go to the primary's instance pool; `GET /retrieve` / `GET /events` / `GET /healthz` / `GET /version` / `GET /openapi.json` / `GET /metrics` can target replicas.

A sample `pgbouncer.ini` ships in `samples/`. Both `maludb-restd` and `maludb-realtimed` have `MALUDB_*_HOST` env vars so the same daemon can be deployed pointed at different upstreams in different pods.

## What stays deferred

- Managed multi-region replica orchestration.
- Active-active replication or multi-master clustering (out of V3 scope per `requirements.md` §1.3).
- Logical replication for tenant-level fan-out.
- Quorum-write topologies.

## Operator checklist before pointing reads at a replica

1. Confirm the replica is caught up: `pg_stat_replication.replay_lag` is steady and small.
2. Confirm physical replication slots exist on the primary — otherwise the replica falls off the primary's WAL retention.
3. Verify the read-only role on the replica can't reach the write surfaces above. The simplest test:
   ```sql
   SET ROLE maludb_memory_executor;
   SELECT queue_enqueue('embed', '{}'::jsonb);
   -- expected: ERROR: cannot execute INSERT in a read-only transaction
   ```
4. Add the replica to the V3-OBS-01 metrics scrape exporter list (`samples/prom-targets.yml`).
5. Schedule a `maludb db restore-check` against a snapshot from the replica to confirm the backup chain still validates from either side.
