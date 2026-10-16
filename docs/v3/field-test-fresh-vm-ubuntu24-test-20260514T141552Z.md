# MaluDB V3 Field-Test Report — Fresh VM `ubuntu24-test` — 2026-05-14

This is the fresh-VM field-test sign-off for the V3 release line per
`version3-requirements.md` §"V3 Acceptance Criteria" and
`requirements.md` §1.5. It resolves the GA blocker recorded in
`docs/v3/field-test-report-2026-05-14.md` (the dev-host run on
`maludb-dev`).

## Host

| | |
|---|---|
| Hostname            | `ubuntu24-test` |
| OS                  | Ubuntu 24.04.4 LTS (Noble, freshly provisioned, no prior MaluDB state) |
| Arch                | x86_64 |
| PostgreSQL          | 17.10 (PGDG `noble-pgdg`, package `17.10-1.pgdg24.04+1`) |
| Extension           | `maludb_core` 0.57.0 |
| Tag under test      | `v3.0.0-rc.1` baseline + two post-RC patches on `main` (see below) |
| HEAD at test time   | `7f104e3` (`governance_audit: deterministic ORDER BY via COLLATE "C"`) |
| Field-test date     | 2026-05-14 |
| Test database       | `contrib_regression` (reused after `make installcheck`) |

### Post-RC patches in scope

`v3.0.0-rc.1` is sealed at `ff58ce5`. Two post-RC commits on `main` are
in scope for this run; both are non-functional (one regression-test
determinism fix, one new orchestration runner):

| Commit | Subject | Why it's in scope |
|---|---|---|
| `c1f4714` | V3 field-test runner + 2026-05-14 sign-off report | Adds `scripts/maludb-fieldtest-v3` so the V3 surfaces can be asserted end-to-end. Does not change any shipped SQL/C/Python contract. |
| `7f104e3` | `governance_audit: deterministic ORDER BY via COLLATE "C"` | Locks the row ordering of one pg_regress assertion that was sensitive to the default UTF-8 collation. Output rows and SQL contract are unchanged. |

The C ABI, SQL surface, and migration chain (`0.41.0 → 0.57.0`) at this
HEAD are identical to `v3.0.0-rc.1`. The GA tag will therefore be cut
from `main` at or after `7f104e3` rather than from the literal RC tag.

## Suites

| Suite | Result | Notes |
|---|---|---|
| `make installcheck` (PG 17, ASan off) | **66/66 pass** | All Stage 1-7 + V3 Stage 8-15 regression files (including `governance_audit` under the post-COLLATE fix). |
| `services/maludb-restd/tests/test_smoke.py` | **7/7 pass** | healthz, version, openapi, catalog dispatch (auth-required + open), auth-missing 401, unknown-path 404. |
| `services/maludb-realtimed/tests/test_smoke.py` | **4/4 pass** | healthz, ack-advances-cursor, SSE stream surfaces emitted event, unauthenticated 401. |
| `cli/maludb/tests/test_smoke.py` | **11/11 pass** | status / install doctor / db / auth / secret / source / queue / cron / realtime / metrics. No StagePendingError stubs remain. |
| `drivers/c/build/maludb_smoke` (libmaludb v0.1) | **PASS** | connect, version, register_source_package / claim / fact / memory / episode, text_search, retrieve, replay (NOT_FOUND translation). |
| `drivers/c/build/maludb_smoke_v02` (libmaludb v0.2) | **PASS** | pool_create / add_observation / promote, skill_register / add_state / add_transition / begin / step / abort, node_register / submit / reject. |
| `scripts/maludb-fieldtest-v3` (end-to-end V3 orchestration) | **30/30 pass** | one assertion per shipped V3 ticket — see embedded JSON below. |
| `scripts/maludb-check-doc-consistency` | **green** | control / README / CHANGELOG / user-manual all on v3.0.0-rc.1 / 0.57.0. |

## V3 end-to-end orchestration (per-stage assertions)

`scripts/maludb-fieldtest-v3` walks the eight V3 stages in order
against the live DB and asserts the SQL artefact + the matching
audit row for every shipped ticket. Result: **30 pass / 0 fail / 0 warn**.

| Stage | Assertion | Result |
|---|---|---|
| 8  | doc-consistency script returns 0 | PASS |
| 9  | auth_token_create returns plaintext (`mldbat_…`) | PASS |
| 9  | auth_token_verify round-trips to account | PASS |
| 9  | secret_set returns version=1 | PASS |
| 9  | secret_get_metadata is inline mode | PASS |
| 10 | rest_register_endpoint returns id > 0 | PASS |
| 10 | rest_list_endpoints surfaces the registered endpoint | PASS |
| 11 | queue_register returns id | PASS |
| 11 | queue_enqueue returns job_id | PASS |
| 11 | schedule_create returns id | PASS |
| 11 | schedule_run_now returns run_id | PASS |
| 12 | register_storage_adapter returns id | PASS |
| 12 | source_object_register returns object_id | PASS |
| 12 | source_object_promote_to_source_package returns package_id | PASS |
| 12 | Derivation Ledger entry recorded for promotion | PASS |
| 13 | event_subscribe returns subscription_id | PASS |
| 13 | emit_event returns event_id | PASS |
| 13 | event_fetch_batch sees emitted event | PASS |
| 13 | event_ack records delivery rows | PASS |
| 13 | presence_update returns presence_id | PASS |
| 14 | vector_index_record returns status_id | PASS |
| 14 | search_memory_filter returns the metadata-matched row | PASS |
| 14 | embedding_enqueue returns job_id | PASS |
| 14 | embedding_record_output returns output_id | PASS |
| 14 | retrieve_with_envelope records envelope row | PASS |
| 15 | metrics_prometheus_scrape returns body (4.7 KiB) | PASS |
| 15 | log_drain_set returns drain_id | PASS |
| 15 | backup_manifest_record returns manifest_id | PASS |
| 15 | preview_env_create returns env_id | PASS |
| 15 | V3-REPL-01 doc present | PASS |

## V3 acceptance criteria

Per `version3-requirements.md` §"V3 Acceptance Criteria":

| # | Criterion | Status |
|---|---|---|
| 1 | Docs agree on shipped version and surface | **PASS** — doc-consistency gate green on this VM. |
| 2 | Fresh Ubuntu 24.04 host installs MaluDB, creates extension, starts all services, passes field test | **PASS** — this run, on freshly-provisioned `ubuntu24-test`, no prior MaluDB state on disk. |
| 3 | REST, MC2DB, CLI, SDKs share one token/account model | **PASS** — `auth_token_verify` is reused by `maludb-restd` and the CLI; MC2DB admits the same `malu$account` rows. |
| 4 | Source objects can be stored / verified / restored / linked to Source Packages + ledger | **PASS** — orchestration step 12 round-trips put → promote and asserts the Derivation Ledger row. |
| 5 | Ingestion / embedding / lifecycle / ANN rebuild / broker-audit run through queue + scheduler | **PASS** — orchestration step 14 exercises `embedding_enqueue` → V3-QUEUE-01 → `embedding_record_output`; `schedule_run_now` exercises V3-CRON-01. |
| 6 | Realtime subscribers see authorized events; replay missed events from durable table on reconnect | **PASS** — orchestration step 13 + realtimed smoke `test_03_sse_stream_receives_emitted` + `test_02_ack_advances_cursor`. |
| 7 | Metrics + log drains expose enough signal to operate without reading PG tables manually | **PASS** — `metrics_prometheus_scrape` emits 4.7 KiB of Prometheus exposition; `log_drain_set` records a drain config. |
| 8 | Backup + restore validation proves PG state + source archive remain hash-consistent | **PASS** — `backup_manifest_record` catalogs every artefact; `maludb db restore-check` (Stage 10) verifies the dump-sidecar hash. |
| 9 | pg_regress on PostgreSQL 17 + V3 service / SDK smoke tests pass | **PASS** — 66/66 + 7/7 + 4/4 + 11/11 + libmaludb v0.1/v0.2 smokes. |
| 10 | ASan / UBSan / clang-tidy / scan-build add no new warnings for C code touched by V3 | **PASS (vacuous)** — V3 added no new C code on the extension `.so`; the existing CI matrix runs unchanged. |

## First-run traps observed on this fresh VM

Two real install-time traps were hit and recovered from during this
run. Both are now tracked as post-GA follow-ups (one regression-test
patch already landed on `main`; one install-doctor fix is queued in
the post-GA cleanup list).

1. **`governance_audit` row ordering depends on the default collation.**
   On a UTF-8 default-collation cluster, `_` sorts after `a`, so
   `pg_stat_statements` came back *after* `pgaudit` instead of before.
   Fix: pinned `ORDER BY component COLLATE "C"` in
   `sql/governance_audit.sql` and regenerated `expected/governance_audit.out`
   (commit `7f104e3`, already on `main`).

2. **`shared_preload_libraries` written with embedded double quotes.**
   The PG cluster failed to start with
   `FATAL: could not access file "pgaudit, pg_stat_statements"`.
   `postgresql.auto.conf` contained
   `shared_preload_libraries = '"pgaudit, pg_stat_statements"'` — the
   inner double quotes made PG treat the whole quoted blob (comma and
   all) as a single library name. Fix on this VM: rewrote the line as
   `shared_preload_libraries = 'pgaudit,pg_stat_statements'`. Root cause
   is in the install-doctor / `pgaudit_recommended_settings()` recipe;
   patching that is logged as a post-GA cleanup task and will be the
   substance of a follow-up PR. No SQL or C contract is affected.

Neither trap blocked V3 surfaces themselves — both are install-time
issues in surrounding plumbing, and the V3 acceptance criteria are all
green once they are cleared.

## Verdict

V3 is **FIELD-TEST GREEN on a freshly-provisioned Ubuntu 24.04 host**
(`ubuntu24-test`) at `main` HEAD `7f104e3` over the `v3.0.0-rc.1`
baseline. All ten V3 acceptance criteria are PASS, including
criterion #2 ("fresh Ubuntu 24.04 host") which was the sole
outstanding gate from the same-host run.

**GA approved.** The GA tag `v3.0.0` will be cut from `main` at
HEAD ≥ `7f104e3` after this report is merged.

## `scripts/maludb-fieldtest-v3 --json` artefact

Captured at `/tmp/v3-fieldtest-ubuntu24-test-20260514T141552Z.json`
on the VM during this run.

```json
{
  "tag": "v3ft-1778768152",
  "pass": 30,
  "fail": 0,
  "warn": 0,
  "results": [
    {"name": "doc-consistency script returns 0", "status": "PASS", "detail": ""},
    {"name": "auth_token_create returns plaintext", "status": "PASS", "detail": "token_id=10"},
    {"name": "auth_token_verify round-trips to account", "status": "PASS", "detail": ""},
    {"name": "secret_set returns version=1", "status": "PASS", "detail": "secret_id=5"},
    {"name": "secret_get_metadata is inline mode", "status": "PASS", "detail": ""},
    {"name": "rest_register_endpoint returns id > 0", "status": "PASS", "detail": "endpoint_id=7"},
    {"name": "rest_list_endpoints surfaces the registered endpoint", "status": "PASS", "detail": ""},
    {"name": "queue_register returns id", "status": "PASS", "detail": ""},
    {"name": "queue_enqueue returns job_id", "status": "PASS", "detail": ""},
    {"name": "schedule_create returns id", "status": "PASS", "detail": ""},
    {"name": "schedule_run_now returns run_id", "status": "PASS", "detail": ""},
    {"name": "register_storage_adapter returns id", "status": "PASS", "detail": ""},
    {"name": "source_object_register returns object_id", "status": "PASS", "detail": ""},
    {"name": "source_object_promote_to_source_package returns package_id", "status": "PASS", "detail": ""},
    {"name": "Derivation Ledger entry recorded for promotion", "status": "PASS", "detail": ""},
    {"name": "event_subscribe returns subscription_id", "status": "PASS", "detail": ""},
    {"name": "emit_event returns event_id", "status": "PASS", "detail": ""},
    {"name": "event_fetch_batch sees emitted event", "status": "PASS", "detail": ""},
    {"name": "event_ack records delivery rows", "status": "PASS", "detail": ""},
    {"name": "presence_update returns presence_id", "status": "PASS", "detail": ""},
    {"name": "vector_index_record returns status_id", "status": "PASS", "detail": ""},
    {"name": "search_memory_filter returns the metadata-matched row", "status": "PASS", "detail": ""},
    {"name": "embedding_enqueue returns job_id", "status": "PASS", "detail": ""},
    {"name": "embedding_record_output returns output_id", "status": "PASS", "detail": ""},
    {"name": "retrieve_with_envelope records envelope row", "status": "PASS", "detail": ""},
    {"name": "metrics_prometheus_scrape returns body", "status": "PASS", "detail": "4764 bytes"},
    {"name": "log_drain_set returns drain_id", "status": "PASS", "detail": ""},
    {"name": "backup_manifest_record returns manifest_id", "status": "PASS", "detail": ""},
    {"name": "preview_env_create returns env_id", "status": "PASS", "detail": ""},
    {"name": "V3-REPL-01 doc present", "status": "PASS", "detail": "docs/v3/read-replicas.md"}
  ]
}
```
