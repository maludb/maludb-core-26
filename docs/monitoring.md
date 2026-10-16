# Monitoring MaluDB with Prometheus

R1.1 ships a Prometheus metrics endpoint on the MC2DB listener.
No additional service to run, no `postgres_exporter` config to
synchronize — the listener queries the catalog on each scrape and
renders the result in Prometheus text format.

## Endpoint

```
GET http://<listener-host>:<listener-port>/metrics
```

The same binding policy as `/healthz`: unauthenticated, intended
for cluster-internal Prometheus. Default listener binding is
`127.0.0.1:5329`, so external exposure requires explicit operator
configuration (`bind_host` in `/etc/maludb/listener.conf`, plus
firewall / reverse proxy as appropriate).

## Exposed metric families

| Metric | Type | Labels | Source |
|---|---|---|---|
| `maludb_mc2dbd_up` | gauge | — | 1 when listener can reach PG |
| `maludb_mc2dbd_invocations_total` | counter | `tool`, `success` | `malu$mc2db_invocation` count |
| `maludb_mc2dbd_invocation_duration_ms_sum` | counter | `tool`, `success` | sum of `duration_ms` |
| `maludb_model_request_count` | gauge | `status` | `malu$model_request` count |

`success` is a string label (`"true"` / `"false"`). Compute average
latency in Prometheus as
`rate(maludb_mc2dbd_invocation_duration_ms_sum[5m]) / rate(maludb_mc2dbd_invocations_total[5m])`.

## Example Prometheus scrape config

```yaml
scrape_configs:
  - job_name: maludb_mc2dbd
    static_configs:
      - targets: ['127.0.0.1:5329']
    metrics_path: /metrics
    scheme: http
    scrape_interval: 15s
```

## Combining with postgres_exporter

The listener metrics cover the MC2DB-layer view of the catalog.
For deeper PG-internal metrics (lock waits, buffer cache, autovacuum,
`pg_stat_statements` queries), run the standard
`prometheus-postgres-exporter` alongside the listener — they don't
overlap.

## Scrape cost

Each `/metrics` GET runs two `GROUP BY` queries on
`malu$mc2db_invocation` and `malu$model_request`. Both tables have
covering indexes (`(tool_id, started_at)` and the partial-index on
`(status, submitted_at)`). At default 15s scrape interval and audit
table size below ~1M rows, the overhead is negligible. Tighter
scrape intervals against larger audit tables warrant a materialized
metrics view; not in scope for R1.1.
