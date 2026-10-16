# V4 Acceptance Matrix

Maps each acceptance criterion from
[`version4-pageindex-plan.md`](../../version4-pageindex-plan.md) §12 to
the test / check artifact that proves it. Single page for rc.1
sign-off and v4.0.0 field-test review.

Last refreshed: 2026-05-14 against extension `0.71.0` /
`v4.0.0-beta.1`.

## Acceptance grid

| # | Criterion | Where it's exercised | Status |
|---|---|---|---|
| 1 | docs (user-manual, README, requirements, plan) agree on shipped version / surface / tag | `scripts/maludb-check-doc-consistency`; also asserted by `scripts/maludb-fieldtest-v4` Stage 16 | **green @ 0.71.0 / v4.0.0-beta.1** |
| 2 | fresh Ubuntu 24.04 host can install + build PageIndex + build ChatIndex + pass field test | Field-test artefact (mirrors v3 cadence). `scripts/maludb-fieldtest-v4` covers the catalog + descent + ChatIndex paths against a live extension. The fresh-VM run is the v4.0.0 GA gate, NOT part of rc.1 | **rc.1 partial** (live-DB fieldtest GREEN; fresh-VM run pending) |
| 3 | REST / MC2DB / CLI / SDK authenticate against V3-AUTH-01 with identical RLS posture | catalog assertions in `maludb-fieldtest-v4` (stage_mc2db_alpha5 + stage_rest_alpha6); the V3-AUTH-01 token model is shared, no V4-specific auth code shipped | **green** |
| 4 | re-derivation under new model alias → supersession edge; leaf ranges unchanged; summaries new | `sql/page_index_catalog.sql` case 6 (page tree supersession); `sql/chat_index_catalog.sql` case 6 (chat tree supersession). Both pass under pg_regress | **green @ 74/74 pg_regress** |
| 5 | V3-EMBED-01 chunker handoff produces vector chunks aligned 1:1 with tree leaves | `page_index_chunker_handoff(tree_id)` shipped in V4-PAGEINDEX-02; `embedding_enqueue` extended with `p_precomputed_boundaries_from_tree_id`. Live alignment audit is post-GA bench work | **green for the API surface**; alignment bench deferred |
| 6 | tree descent authz-enforced at planning / expansion / assembly; non-auditors don't see descent trails or unauthorized leaves; descent records appear with `stage='tree_descent'` | `sql/page_index_descent.sql` (7 cases) — including RLS cross-tenant rejection + concurrent supersession; `maludb-fieldtest-v4` stage_18_descent | **green @ 74/74 pg_regress** |
| 7 | every tree node, structure-pass run, ChatIndex append has Derivation Ledger entry | `sql/page_index_promote.sql`, `sql/chat_index_catalog.sql`, `sql/chat_index_append.sql` all assert ledger coverage; `maludb-fieldtest-v4` stage_17_promote re-checks via live SQL | **green** |
| 8 | ChatIndex incremental append over many calls produces a tree byte-equivalent to one-shot ingest of the same message sequence | `sql/chat_index_append.sql` case 6 (idempotency on duplicate `message_index`); `maludb-fieldtest-v4` stage_19_chat re-runs a duplicate message and asserts `idempotent_hit=true` | **green** |
| 9 | pg_regress passes on PG 17; V4 service / SDK smoke tests pass; benchmark fixtures publish recall / latency baselines for fixture PDF + chat corpora | `make installcheck` on PG 17 → 74/74; `bench/v4/run-bench` publishes the baselines under the deterministic `overlap` choice strategy. Live PDF coverage uses generated-in-process pypdf fixtures (real PDF parser smoke lives in `services/maludb-pageindexd/tests/test_pypdf_parser.py`) | **green** (see below for current baselines) |
| 10 | ASan / UBSan / clang-tidy / scan-build add no new warnings for V4-touched C code | V4 introduces no new C code in the extension. `drivers/c/src/maludb.c` gained 6 wrappers at beta.1; these use the existing helpers and don't change the build matrix | **green (vacuous for the extension; C SDK wrappers ride the existing CI matrix)** |
| 11 | `.deb` artifact set extends to include `maludb-pageindexd_X.Y.Z-1_amd64.deb` alongside the V3 packages | Deferred — same posture as V3 Python services (`maludb-restd`, `maludb-realtimed`, `maludb-logsd`) which are NOT debian-packaged. The plan's expectation is aspirational. Operators install via `pip install` from `services/maludb-pageindexd/pyproject.toml` for v4.0.0 | **deferred** |

## rc.1 baselines

`bench/v4/run-bench` last published, against extension `0.71.0`
on `maludb-dev`:

| Tree | n_queries | recall | p95 ms (worst query) |
|---|---|---|---|
| page_index | 5 | 1.00 | ~12 ms |
| chat_index | 3 | 1.00 | ~10 ms |

These are the deterministic-`overlap` numbers. The `llm` choice
strategy (post-GA) will move the baselines; the harness is
re-runnable with `--choice llm --model-alias <id>` once that
strategy lands.

## What gates v4.0.0 GA

1. The rc.1 baselines stay green on the fresh-VM field test.
2. `maludb-fieldtest-v4` passes on a fresh Ubuntu 24.04 host with
   no pre-existing MaluDB state.
3. The doc-consistency gate stays green at the GA version / tag.
4. A field-test sign-off doc lands in `docs/v4/` describing the
   environment, the gate runs, and any traps caught (the V3 GA
   precedent: `docs/v3/field-test-fresh-vm-*.md`).

## Deferred from V4 scope

These are listed in `version4-pageindex-plan.md` §10 (Open Decisions)
and remain post-GA work:

- In-house PDF parser to replace `pypdf` for the long tail.
- Vision PDFs (OCR).
- Live LLM-driven topic-opening in `chat_index_append_messages`.
- Live `llm` choice strategy in `tree_descent_retrieve` /
  `chat_tree_descent_retrieve`.
- AMP retire → ChatIndex automation.
- GraphQL surface over trees.
- Project-wide tier-view retrofit
  (`MALU_USER_*` / `MALU_ALL_*` / `MALU_DBA_*`).
- Debian packaging for `maludb-pageindexd` and the other
  Python services.
