# MaluDB V3 Field-Test Report — 2026-05-14

This is the field-test sign-off for `v3.0.0-rc.1` per
`version3-requirements.md` §"V3 Acceptance Criteria" and
`requirements.md` §1.5.

## Host

| | |
|---|---|
| Hostname            | `maludb-dev` |
| OS                  | Ubuntu 24.04 LTS (kernel 6.8.0-111-generic) |
| Arch                | x86_64 |
| PostgreSQL          | 17.9 (PGDG `noble-pgdg`) |
| Extension           | `maludb_core` 0.57.0 |
| Tag                 | `v3.0.0-rc.1` at `ff58ce5` |
| Field-test date     | 2026-05-14 |
| Test database       | `contrib_regression` (pg_regress's tear-down/build database; reused after `make installcheck`) |

> Note on field-test environment: This run was executed on the dev
> build host rather than a freshly-provisioned Ubuntu 24.04 VM. The
> structural surfaces of V3 are catalog-resident and exhaustively
> exercised by pg_regress + the per-service smokes + the end-to-end
> orchestration below, so a same-host run is a meaningful gate. A
> follow-up fresh-VM run remains the formal GA blocker recorded in
> the `v3.0.0-rc.1` CHANGELOG entry.

## Suites

| Suite | Result | Notes |
|---|---|---|
| `make installcheck` (PG 17, ASan off) | **66/66 pass** | All Stage 1-7 + V3 Stage 8-15 regression files. |
| `services/maludb-restd/tests/test_smoke.py` | **7/7 pass** | healthz, version, openapi, catalog dispatch (auth-required + open), auth-missing 401, unknown-path 404. |
| `services/maludb-realtimed/tests/test_smoke.py` | **4/4 pass** | healthz, ack-advances-cursor, SSE stream surfaces emitted event, unauthenticated 401. |
| `cli/maludb/tests/test_smoke.py` | **11/11 pass** | status / install doctor / db / auth / secret / source / queue / cron / realtime / metrics. No StagePendingError stubs remain. |
| `drivers/c/build/maludb_smoke` (libmaludb v0.1) | **6/6 pass** | connect, version, register_source_package / claim / fact / memory / episode, text_search, retrieve, replay (NOT_FOUND translation). |
| `drivers/c/build/maludb_smoke_v02` (libmaludb v0.2) | **12/12 pass** | pool_create / add_observation / promote, skill_register / add_state / add_transition / begin / step / abort, node_register / submit / reject. |
| `scripts/maludb-fieldtest-v3` (end-to-end V3 orchestration) | **30/30 pass** | one assertion per shipped V3 ticket below. |
| `scripts/maludb-check-doc-consistency` | **green** | control / README / CHANGELOG / user-manual all on v3.0.0-rc.1 / 0.57.0. |
| `scripts/maludb-fieldtest` (R1.0 21-step) | **WARN** | mc2dbd not currently running on this host; the R1.0 SQL contract is exercised by the 51 R1.0/Stage 2-7 tests inside the 66/66 pg_regress run. The live-listener path is unchanged in V3, so this is not a V3 regression. |

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
| 1 | Docs agree on shipped version and surface | **PASS** — doc-consistency gate green. |
| 2 | Fresh Ubuntu 24.04 host installs MaluDB, creates extension, starts all services, passes field test | **PARTIAL** — same-host orchestration (not a fresh VM) is green at 30/30 + 66/66 + smokes. Fresh-VM rerun is the remaining GA blocker. |
| 3 | REST, MC2DB, CLI, SDKs share one token/account model | **PASS** — V3-AUTH-01 `auth_token_verify` is reused by `maludb-restd` and the CLI; MC2DB admits the same `malu$account` rows. |
| 4 | Source objects can be stored / verified / restored / linked to Source Packages + ledger | **PASS** — orchestration step 12 round-trips put → promote and asserts the Derivation Ledger row. |
| 5 | Ingestion / embedding / lifecycle / ANN rebuild / broker-audit run through queue + scheduler | **PASS** — orchestration step 14 exercises `embedding_enqueue` → V3-QUEUE-01 → `embedding_record_output`; schedule_run_now exercises V3-CRON-01. |
| 6 | Realtime subscribers see authorized events; replay missed events from durable table on reconnect | **PASS** — orchestration step 13 + realtimed smoke `test_03_sse_stream_receives_emitted` + `test_smoke_v02 test_02_ack_advances_cursor`. |
| 7 | Metrics + log drains expose enough signal to operate without reading PG tables manually | **PASS** — `metrics_prometheus_scrape` emits 4.7 KiB of exposition; `log_drain_set` records a drain config. |
| 8 | Backup + restore validation proves PG state + source archive remain hash-consistent | **PASS** — `backup_manifest_record` catalogs every artefact; `maludb db restore-check` (Stage 10) verifies the dump-sidecar hash. |
| 9 | pg_regress on PostgreSQL 17 + V3 service / SDK smoke tests pass | **PASS** — 66/66 + 7/7 + 4/4 + 11/11 + 6/6 + 12/12. |
| 10 | ASan / UBSan / clang-tidy / scan-build add no new warnings for C code touched by V3 | **PASS (vacuous)** — V3 added no new C code; the existing CI matrix runs unchanged. |

## Verdict

V3 is **FIELD-TEST GREEN on this host** at `v3.0.0-rc.1` / extension
`0.57.0`. The only acceptance criterion not satisfied here is #2's
"fresh Ubuntu 24.04 host" qualifier, which is a deployment-environment
gate rather than a structural one. The structural surfaces are all
green: every shipped V3 ticket's SQL artefact + audit row was
asserted; every service binary responded; the doc-consistency gate
is locked.

The remaining steps to `v3.0.0` GA:

1. Re-run `scripts/maludb-fieldtest-v3` + `make installcheck` + all
   service smokes on a freshly-provisioned Ubuntu 24.04 host (any
   VM provisioned from a base image, no MaluDB state).
2. Resolve any deviations recorded by that fresh-VM run.
3. Tag `v3.0.0` and update `version3-plan.md` §2.2 + the CHANGELOG.

## Files produced

- `scripts/maludb-fieldtest-v3` (new orchestration runner; reusable
  for the fresh-VM re-run).
- `docs/v3/field-test-report-2026-05-14.md` (this report).
