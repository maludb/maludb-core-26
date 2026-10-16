# MaluDB v3.1.0 — release summary

**Tag**: `v3.1.0`
**Date**: 2026-05-14
**Extension**: `0.64.0` (8 new migrations, `0.57.0 → 0.64.0`)
**Status**: GA

`v3.1.0` is the platform-ergonomics follow-up release after `v3.0.0`
GA on the same day. Every ticket logged in `v3_scope` memory's
"V3 follow-ups" list either ships here or is recorded as a
deferred-with-acceptance-criteria follow-up.

## Headline

* **Auth**: C-backed HMAC + HS256 JWT verifier on the token-verify
  hot path. RS/ES/EdDSA dispatch is now in C and raises
  `feature_not_supported` (asymmetric algorithms ship in V3-AUTH-03).
* **Secret**: C-backed `file://` (allowlist + lstat + 0400/0600
  + uid check) and `https://` (libcurl + TLS verify) secret
  resolvers.
* **Storage**: S3 adapter end-to-end via stdlib AWS Signature v4 (no
  boto3). New `maludb source signed-url` CLI subcommand.
* **Logging**: `maludb-logsd` service runner pulls audit /
  realtime_event streams past per-drain cursors and ships to
  file/http sinks.
* **Realtime**: WebSocket transport at `/events/ws` alongside SSE,
  with inline `{"ack": N}` ack frames.
* **REST**: 20 curated endpoints seeded into `malu$rest_endpoint`
  with typed-arg dispatch; `maludb-restd` binds JSON body fields to
  named PL/pgSQL parameters with per-type coercion.
* **CLI**: env / log-drain / backup subcommand families.
* **Memory model**: Ledger gains the `embedding` kind; presence
  rows can have a TTL with a `presence_sweep()` reaper;
  Stage 2/5/6 `register_*` helpers emit realtime events
  automatically.
* **Vector**: Reproducible benchmark harness
  (`scripts/maludb-bench-vector`) writing recall summaries into
  `malu$vector_index_status.recall_sample`.
* **Ops**: pgmq/pg_cron adoption decision recorded
  (`docs/v3/pgmq-pgcron-decision.md`); PgBouncer + HAProxy sample
  configs (`docs/v3/samples/`).

## Migration chain

| From | To | Stage | Ticket |
|---|---|---|---|
| `0.57.0` | `0.58.0` | A | V3-EMBED-02 ledger `embedding` kind |
| `0.58.0` | `0.59.0` | B | V3-REALTIME-02a `emit_event` in Stage 2/5/6 `register_*` |
| `0.59.0` | `0.60.0` | C | V3-PRESENCE-02 TTL + `presence_sweep()` |
| `0.60.0` | `0.61.0` | E | V3-LOG-02 log-drain cursors + fetch_batch |
| `0.61.0` | `0.62.0` | F | V3-API-02 `malu$rest_endpoint.arg_schema` + 20-endpoint seed |
| `0.62.0` | `0.63.0` | H | V3-AUTH-02 C-backed HMAC + JWT verifier |
| `0.63.0` | `0.64.0` | I | V3-SECRET-02 C-backed file/https resolver |

Stages D (CLI wrappers), G (WebSocket), J (S3 adapter), K (vector
bench), L (pgmq/pg_cron decision), M (PgBouncer/HAProxy samples)
ship without a migration — they live in CLI / services / docs.

## Gate matrix

Captured on the dev host at the `v3.1.0` cut.

| Suite | Result |
|---|---|
| `make installcheck` (PG 17, ASan off) | **69/69 pass** |
| `services/maludb-restd` smoke | **9/9 pass** |
| `services/maludb-realtimed` smoke | **6/6 pass** |
| `services/maludb-logsd` smoke | **4/4 pass** |
| `cli/maludb` smoke | **15/15 pass** |
| `scripts/maludb-fieldtest-v3` | **30 pass / 0 fail / 0 warn** |
| `scripts/maludb-check-doc-consistency` | **OK** (default_version 0.64.0, release tag v3.1.0) |

## Follow-ups deferred past v3.1.0

Each item below is a **conditional** future stage. Acceptance
criteria are recorded inline so the door is left open without
shipping unfinished work.

* **V3-AUTH-03** — RS256 / RS384 / RS512 / ES256 / ES384 / ES512 /
  EdDSA verifier branches. The C dispatcher is in place and raises
  `feature_not_supported` for unsupported algorithms; only the
  per-algorithm `EVP_DigestVerify` plumbing is missing. Acceptance:
  the V3-AUTH-02 regression test (`sql/c_hmac_jwt.sql`) gains
  per-algorithm happy-path and tampered-signature cases.
* **V3-VEC-03** — multilevel HNSW in `src/maludb_ann.c`, plus the
  SQL search wrapper. Acceptance: the existing bench harness gets
  a non-zero `nsw` and `hnsw_local` row in
  `malu$vector_index_status.recall_sample` with recall@10 ≥ 0.95
  on the seeded corpus.
* **V3-VEC-04** — pgvector HNSW integration via a parallel `vector`
  column (since `malu_vector` is our own type). Acceptance: the
  bench harness gets a `hnsw_pgvector` row with the same recall
  floor.
* **V3-STOR-03** — `maludb-restd` parity for S3 adapter dispatch.
  The CLI ships S3 fully; restd currently dispatches storage
  reads/writes through its own path. Acceptance: a restd smoke
  test mirroring CLI `test_15_s3_signed_url_round_trip`.
* **V3-QUEUE-03** — Conditional pgmq adoption. Triggers on either
  pgmq landing in PGDG or sustained queue throughput exceeding
  10k enqueue/s on the native path.
* **V3-LOG-03** — Additional stream sources in
  `log_drain_fetch_batch` (currently `audit` + `realtime_event`):
  `queue`, `mc2db`, `postgres`.
* **V3-SECRET-03** — `env://` resolver kind for K8s-style
  env-injected secrets. Mechanism is the same as file:// but reads
  `getenv(VAR_NAME)`.

## Operator action required

* **None** to upgrade from `v3.0.1` if the operator does not use
  external secret refs, S3 storage, or JWT auth. The migrations are
  additive and existing inline secrets / local_fs adapters keep
  working unchanged.
* **Optional**: adopt `pg_cron` as the V3-CRON-01 tick driver per
  `docs/v3/pgmq-pgcron-decision.md` § "pg_cron — adopt as an
  *optional* tick driver".
* **Optional**: register `oct` JWK signing keys for HS256 if the
  operator wants real JWT verification (the algorithm CHECK in
  `malu$jwt_signing_key` was extended to include `HS256` / `oct`).
* **Optional**: drop in `docs/v3/samples/pgbouncer.ini` +
  `docs/v3/samples/haproxy.cfg` if the operator runs a primary +
  replica setup.

## Build / dependency changes

* `Makefile` `SHLIB_LINK` gained `-lcrypto` (Stage H) and `-lcurl`
  (Stage I). Both ship by default on Ubuntu 24.04 + PGDG (already
  required by pgcrypto and the project's install doc).
* `.gitignore` extended for `**/__pycache__/` and
  `**/docs/claude-log/`.

## v3.0.x supersession

`v3.1.0` supersedes `v3.0.0`, `v3.0.0-rc.1`, and `v3.0.1`. The
`v3.0.x` tags remain in git history but receive no further patches.
Operators on the `v3.0.x` line should run `ALTER EXTENSION
maludb_core UPDATE TO '0.64.0'` after `sudo make install` from the
`v3.1.0` source tree; the migration chain is sequential and
idempotent.
