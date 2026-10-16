# maludb-logsd

V3-LOG-02 log-drain forwarder for MaluDB.

Polls `malu$log_drain` rows, pulls new records from each subscribed
source stream past the per-drain cursor, ships them to the configured
sink (file / http / s3 / otlp_http), records a `malu$log_drain_run`
row, and advances the cursor on success.

## Supported streams

| Stream | Source table | Status |
|---|---|---|
| `audit` | `malu$audit_event` | shipped (Stage E) |
| `realtime_event` | `malu$event` | shipped (Stage E) |
| `queue` | `malu$queue_run` | TODO (followup) |
| `mc2db` | `malu$model_request` / `malu$model_response` | TODO (followup) |

## Supported sinks

| Sink | Mode | Status |
|---|---|---|
| `file` | append JSONL to `destination.path` | shipped |
| `http` | POST JSON batch to `destination.url` | shipped |
| `s3` | upload JSONL batch to `s3://bucket/key_prefix/<ts>.jsonl` | TODO (Stage J follow-up) |
| `otlp_http` | POST OTLP/HTTP logs to `destination.endpoint` | TODO (followup) |

## Environment

| Variable | Purpose |
|---|---|
| `MALUDB_LOGSD_DB` | database name (required) |
| `MALUDB_LOGSD_HOST` / `_PORT` / `_USER` / `_PASSWORD` | libpq overrides |
| `MALUDB_LOGSD_POLL_INTERVAL_MS` | poll cadence (default 5000 ms) |
| `MALUDB_LOGSD_BATCH_SIZE` | per-stream fetch batch (default 100) |
| `MALUDB_LOGSD_LOG_LEVEL` | INFO / DEBUG / WARNING |

## Test surface

`tests/test_smoke.py` exercises:

* file sink end-to-end for `audit`
* http sink end-to-end for `realtime_event`, with a stdlib
  `http.server.BaseHTTPRequestHandler` collecting the POST body
* cursor advance + run-row recording

## Operational notes

* The daemon is intentionally single-process and stateless aside from
  PG-side cursors. Restart-safety comes from `log_drain_advance_cursor`
  only writing after a successful sink delivery.
* When a drain has a `destination_secret_ref`, the secret is resolved
  via `malu$secret`'s inline path. External secret resolvers
  (file:// / https://) come in V3-SECRET-02 (Stage I).
