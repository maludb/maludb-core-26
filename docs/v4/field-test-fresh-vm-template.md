# MaluDB V4 Field-Test Report — Fresh VM `<HOSTNAME>` — `<YYYY-MM-DD>`

Fresh-VM field-test sign-off for the V4 release line per
[`version4-pageindex-plan.md`](../../version4-pageindex-plan.md) §12.
Resolves the only outstanding gate from
[`acceptance-matrix.md`](acceptance-matrix.md) criterion #2.

**How to use this template:** copy it to
`docs/v4/field-test-fresh-vm-<host>-<ISO timestamp>.md`, run the steps,
fill in the placeholders. When every section is green, the v4.0.0 GA
tag is approved.

---

## Host

| | |
|---|---|
| Hostname             | `<HOSTNAME>` |
| OS                   | Ubuntu 24.04.<minor> LTS (Noble, freshly provisioned, no prior MaluDB state) |
| Arch                 | `<x86_64 or arm64>` |
| PostgreSQL           | 17.<x> (PGDG `noble-pgdg`, package `<exact version>`) |
| Extension            | `maludb_core` 0.71.0 |
| Tag under test       | `v4.0.0-rc.1` |
| HEAD at test time    | `<commit-sha>` (`<commit subject>`) |
| Field-test date      | `<YYYY-MM-DD>` |
| Test database        | `contrib_regression` (reused after `make installcheck`) |
| Tester               | `<your name / handle>` |

### Post-RC patches in scope (if any)

If `main` advanced past `v4.0.0-rc.1` before this run, list them here.
Each row MUST be either a non-functional fix (test determinism, doc,
typo) or accompanied by a justification.

| Commit | Subject | Why it's in scope |
|---|---|---|
| `<sha>` | `<subject>` | `<rationale>` |

---

## Suites

Run each suite and record PASS/FAIL with the count. A FAIL anywhere
means we don't tag v4.0.0 — fix on `main`, re-run, update this report.

| Suite | Expected | Result | Notes |
|---|---|---|---|
| `make installcheck` (PG 17, default build) | **74/74 pass** | `<XX/74>` | All Stage 1–7 + V3 Stage 8–15 + V4 Stage 16–19 regression files. |
| `services/maludb-restd/tests/test_smoke.py` | **7/7 pass** | `<X/7>` | V3 surface — should still be green. |
| `services/maludb-realtimed/tests/test_smoke.py` | **4/4 pass** | `<X/4>` | V3 surface — should still be green. |
| `services/maludb-pageindexd/tests/` (parser smokes) | **14/14 pass** | `<XX/14>` | V4-PARSER-01 unittests. Requires `python3-pypdf` apt package. |
| `cli/maludb/tests/test_smoke.py` | **11/11 pass** | `<XX/11>` | V3 CLI families. The new pageindex/chatindex modules are exercised only by import (no live-DB stub yet); see fieldtest-v4 below. |
| `drivers/c/build/maludb_smoke` (libmaludb v0.1) | **PASS** | `<PASS/FAIL>` | V3 C SDK round-trip. |
| `drivers/c/build/maludb_smoke_v02` (libmaludb v0.2) | **PASS** | `<PASS/FAIL>` | V3 C SDK pool/skill/node round-trip. |
| `scripts/maludb-fieldtest-v4` | **28/28 pass** | `<XX/28>` | End-to-end V4 orchestration. Per-stage assertions captured below. |
| `bench/v4/run-bench` | **recall ≥ 0.80 each tree** | `<page=XX  chat=XX>` | Deterministic-overlap descent baselines. |
| `scripts/maludb-check-doc-consistency` | **green** | `<green/red>` | Control / README / CHANGELOG / user-manual all agree on `0.71.0 / v4.0.0-rc.1`. |

---

## V4 end-to-end orchestration (per-stage assertions)

`scripts/maludb-fieldtest-v4` walks every V4 surface in order against
the live extension. Result: **`<XX>` pass / `<XX>` fail**.

| Stage | Assertion | Result |
|---|---|---|
| 16 | doc-consistency script returns 0 | `<PASS/FAIL>` |
| 16 | doc mentions PageIndex / Version 4 | `<PASS/FAIL>` |
| 17a | register_source_package returns id > 0 | `<PASS/FAIL>` |
| 17a | page_index_tree_register returns id > 0 | `<PASS/FAIL>` |
| 17a | tree is in 'pending' status | `<PASS/FAIL>` |
| 17a | tree advances to 'ready' | `<PASS/FAIL>` |
| 17a | audit rows recorded for tree transitions | `<PASS/FAIL>` |
| 17b | source_package_promote_to_page_index returns tree id | `<PASS/FAIL>` |
| 17b | pageindex_build queue job enqueued | `<PASS/FAIL>` |
| 17b | page_index_record_structure_pass writes audit row | `<PASS/FAIL>` |
| 17b | page_index_record_node returns mdo + derivation | `<PASS/FAIL>` |
| 17b | ledger entries for every recorded node | `<PASS/FAIL>` |
| 18 | retrieve_with_envelope_tree returns a hit | `<PASS/FAIL>` |
| 18 | descent lands on the 'Methods' leaf | `<PASS/FAIL>` |
| 18 | tree_descent decision_audit rows recorded | `<PASS/FAIL>` |
| 18 | envelope captured tree_descent_path | `<PASS/FAIL>` |
| 18 | retrieval_summary ledger entries recorded | `<PASS/FAIL>` |
| 19 | chat_index_tree_register returns id > 0 | `<PASS/FAIL>` |
| 19 | append returns one row per message | `<PASS/FAIL>` |
| 19 | first-append audit: opened_new_topic=true | `<PASS/FAIL>` |
| 19 | branch-from-current: opened=true, ancestor=false | `<PASS/FAIL>` |
| 19 | duplicate message_index returns idempotent_hit=true | `<PASS/FAIL>` |
| 19 | retrieve_with_envelope_chat_tree returns hit | `<PASS/FAIL>` |
| α.5 | all 8 V4 MC2DB tools registered on maludb.advanced | `<PASS/FAIL>` |
| α.6 | all 8 V4 REST endpoints registered | `<PASS/FAIL>` |
| β.1 | maludb_cli.commands.pageindex importable | `<PASS/FAIL>` |
| β.1 | maludb_cli.commands.chatindex importable | `<PASS/FAIL>` |
| β.1 | MaluDBClient exposes all 9 V4 methods | `<PASS/FAIL>` |

---

## V4 bench baselines

`bench/v4/run-bench` published on this VM:

| Tree | n_queries | recall | p50 ms (median across queries) | p95 ms (worst query) |
|---|---|---|---|---|
| page_index | 5 | `<X.XX>` | `<X.X>` | `<X.X>` |
| chat_index | 3 | `<X.XX>` | `<X.X>` | `<X.X>` |

Bench acceptance gate: **recall ≥ 0.80 each tree**, **p95 < 100 ms** under
the deterministic `overlap` strategy on the fixture corpus.

---

## V4 acceptance criteria (per plan §12)

| # | Criterion | Result |
|---|---|---|
| 1 | Docs agree on shipped version / surface / tag | `<PASS/FAIL>` |
| 2 | Fresh Ubuntu 24.04 host installs, starts services, passes field test | `<PASS/FAIL>` — **this run** |
| 3 | REST / MC2DB / CLI / SDKs share V3-AUTH-01 token model with identical RLS | `<PASS/FAIL>` |
| 4 | Re-derivation produces supersession edge; leaf ranges unchanged; new summaries | `<PASS/FAIL>` — `sql/page_index_catalog.sql` + `sql/chat_index_catalog.sql` |
| 5 | V3-EMBED-01 chunker handoff aligned 1:1 with tree leaves | `<PASS — API surface; bench-deferred>` |
| 6 | Tree descent authz-enforced at planning / expansion / assembly | `<PASS/FAIL>` — `sql/page_index_descent.sql` |
| 7 | Every tree node, structure-pass run, ChatIndex append has Derivation Ledger entry | `<PASS/FAIL>` |
| 8 | ChatIndex incremental append byte-equivalent to one-shot ingest | `<PASS/FAIL>` — `sql/chat_index_append.sql` |
| 9 | pg_regress passes on PG 17; V4 service / SDK smoke tests pass; bench fixtures publish baselines | `<PASS/FAIL>` |
| 10 | ASan / UBSan / clang-tidy / scan-build add no new warnings for V4-touched C code | `<PASS — vacuous; V4 adds no extension C>` |
| 11 | `.deb` artifact set extends to include maludb-pageindexd_X.Y.Z-1_amd64.deb | **deferred** — same posture as V3 Python services |

---

## First-run traps observed

If anything in `make installcheck` / `maludb-fieldtest-v4` / the bench
broke on first contact, record it here. Each entry should describe
the failure mode, the on-VM workaround, and where the root cause
should be patched. Aim to convert each trap to a follow-up PR after
GA.

1. **`<one-line summary>`** — `<failure mode + recovery + root-cause patch target>`.
2. …

If nothing tripped, write "none observed" and move on.

---

## Verdict

V4 is **`<FIELD-TEST GREEN / BLOCKED>`** on a freshly-provisioned
Ubuntu 24.04 host (`<HOSTNAME>`) at HEAD `<sha>` over the
`v4.0.0-rc.1` baseline. All 11 V4 acceptance criteria are
`<PASS/PASS-DEFERRED/FAIL>`.

**`<GA approved / GA blocked pending …>`.** If approved, the GA tag
`v4.0.0` is cut from `main` at HEAD ≥ `<sha>` after this report is
merged.

---

## `scripts/maludb-fieldtest-v4 --json` artefact (optional)

If you want a machine-readable record, run with `--json > path/to.json`
and paste the result here in a fenced block.

```json
<paste fieldtest JSON here, or note "not captured this run">
```
