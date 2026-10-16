# MaluDB post-alpha roadmap (v2.0.0-alpha.4 → v2.0.0)

**Purpose.** This document is the starting point for the next
working session. It captures everything left to close the gap from
the current public alpha (`v2.0.0-alpha.4`, tagged 2026-05-13) to
the v2.0.0 GA release. `requirements.md` §9 is fully shipped; this
document covers the *quality* and *distribution* polish that wasn't
in scope for §9 but is needed before GA.

If you're resuming from a cold context, read this end-to-end first.
Then pick a phase and start. Each phase lists its acceptance
criteria and the files it touches.

## Current state snapshot

| | |
|---|---|
| Last tag | **`v2.0.0-alpha.4`** at commit `2f457a9` |
| Extension version | **0.41.0** (41 migration files) |
| Test suite | **51/51 pg_regress** on PG 17 |
| Packages | `postgresql-{16,17,18}-maludb-core_0.41.0-1` + `maludb-mc2dbd_0.41.0-1` |
| Drivers (validated against live extension) | Python ✅ Node.js ✅ PHP ✅ C ✅ |
| External services | `mc2dbd` (R1.0) + `mcp-broker` (S6-5) |
| Security review | All three S7-2 findings closed |
| Roadmap | `requirements.md` §9 fully shipped |

What ships today on a fresh `apt install` of the four `.deb` files:

- The 41-step `maludb_core` extension chain for PG 16, 17, or 18.
- The `mc2dbd` MCP listener daemon with the four
  `implementation_type` dispatchers.
- The `mcp-broker` reference broker for external (non-database)
  tools.
- Two MC2DB servers in the catalog: `maludb.r10` (R1.0 narrow
  surface) and `maludb.advanced` (Stage 2..6 surface, 19 tools).

What is NOT yet in distribution:

- Field-test on a clean Ubuntu 24.04 VM (Phase F).
- Lintian-clean `.deb` files, apt-repo upload (Phase D).
- C SDK v0.2.0 (pool / skill / node wrappers; Phase C).
- Broker v0.2.0 (HTTP + mcp_proxy tool kinds, HTTPS transport,
  audit-loop closure into `malu$mc2db_invocation`; Phase B).

## Doctrine the next session must respect

These are non-negotiable. They come from `CLAUDE.md`, the
`white-paper.md` (frozen), and `requirements.md` (authoritative).

1. **Corrections never silently overwrite history.** Supersession
   closes a `valid_time_end`, opens a new version, records a
   `malu$supersession_edge`. The Temporal Supersession Engine owns
   this; never write directly.
2. **Provenance is mandatory.** Every derived object has a
   `malu$derivation_ledger` entry.
3. **Authorization is checked at three points** — planning,
   expansion, assembly. Never only at the final answer.
4. **Multi-model writes are atomic.** Wrap in one SQL transaction.
   Partial commits are forbidden.
5. **Nodes are never authoritative.** They submit proposals;
   `node_accept` applies them through the normal `register_*`
   helpers under RLS + governance.
6. **Workflow candidates don't auto-promote.** Approving flips a
   `review_status` only.

Project conventions:

- Migrations land as `maludb_core--X.Y.0--X.(Y+1).0.sql`.
- Stage-boundary roadmap (`stage_boundary_violations()`) is per-phase
  maintenance — drop sentinel rows when their tables land.
- Tagged dollar quotes (`$body$ … $body$`) — never bare `$$ … $$` —
  because `malu$<name>` clashes with untagged dollar quoting.
- Risk-class values for MC2DB tools: `read_only`, `evidence_producing`,
  `state_changing`, `external_effect`, `administrative`. Not `'write'`.
- pgvector / pgaudit / pg_partman are runtime deps; do NOT add to
  `Build-Depends` (PGXS compile doesn't need them).
- `debian/.gitignore` already exists; keep build artefact trees out
  of git.
- The C driver's `function_signature` column references are
  `regprocedure`, NOT text. Existence check is automatic at INSERT.
- Caller's psql `:var` doesn't interpolate inside DO `$body$` blocks
  — fetch values inside the DO block with a SELECT instead.

## Phase plan (sequenced)

```
v2.0.0-alpha.4   (now)
       │
       ▼
       Phase F (field-test) + Phase P (test polish)  ~3 h
       │
       ▼
v2.0.0-alpha.5   friction fixes
       │
       ▼
       Phase D (lintian + apt-repo)                  ~2 h
       │
       ▼
v2.0.0-beta      distributable
       │
       ▼
       Phase C (C SDK v0.2.0) + Phase X (docs)       ~3 h
       │
       ▼
v2.0.0-rc1       full driver parity
       │
       ▼
       Phase B (broker v0.2.0 + audit ingest)        ~6 h
       │
       ▼
v2.0.0           GA
```

Total work to GA: **~14 hours** across 2–4 sessions.

---

# Phase F — Field-test the alpha *(do first, ~2 h)*

Validate the alpha on a fresh Ubuntu 24.04 VM. The whole point of
an alpha tag — this is where first-run issues surface.

## Tasks

### F-1: Spin up a fresh Ubuntu 24.04 LTS VM

Acceptance: `lsb_release -a` shows Ubuntu 24.04, `uname -m` is
x86_64 or aarch64, no MaluDB-related packages installed.

### F-2: Install the four `.deb` files

```bash
# Copy the four .debs from the build host:
scp ../postgresql-1{6,7,8}-maludb-core_0.41.0-1_amd64.deb \
    ../maludb-mc2dbd_0.41.0-1_amd64.deb \
    ubuntu-vm:/tmp/

# On the VM:
sudo apt-get install -y /tmp/postgresql-17-maludb-core_0.41.0-1_amd64.deb \
                        /tmp/maludb-mc2dbd_0.41.0-1_amd64.deb
sudo apt-get -f install   # pull pgvector / pgaudit / partman
```

Acceptance: `dpkg -l | grep maludb` shows both packages installed.

### F-3: First-run smoke

```bash
sudo -u postgres createdb fieldtest
sudo -u postgres psql -d fieldtest -c "CREATE EXTENSION maludb_core CASCADE"
sudo -u postgres psql -d fieldtest -c "SELECT maludb_core.maludb_core_version()"
# expected: 0.41.0
```

Acceptance: version returns `0.41.0` without errors.

### F-4: Run `make installcheck` on PG 16 and PG 18

The current 51/51 has only been verified on PG 17. The .deb chain
covers 16/17/18; the regression suite has never been run against
16 or 18 in this session. Likely-but-unverified failure modes:

- `tstzrange` literal formatting differences across majors.
- Function-resolution rule changes (PG 18 tightened some rules).
- pgvector index-build changes.

Process: install postgresql-16-maludb-core (and `postgresql-16`
itself), create a regression database on the PG 16 cluster, run
`make installcheck PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config`.
Adopt any version-specific `expected/*.out` drift by saving a
matching `expected/<name>_1.out` (pg_regress accepts that pattern).
Repeat for PG 18.

Acceptance: 51/51 passes on each of PG 16, 17, 18. Diffs adopted
into per-version `expected/*_1.out` files where genuinely
version-specific.

### F-5: Run all four driver smoke tests + examples

```bash
# Python
cd drivers/python
python3 -m venv .venv && .venv/bin/pip install -e '.[test]'
MALUDB_TEST_DSN="postgresql:///fieldtest?host=/var/run/postgresql" \
    .venv/bin/pytest -v

# Node.js
cd drivers/nodejs
npm install
MALUDB_TEST_DSN="postgresql:///fieldtest?host=/var/run/postgresql" \
    npm test

# PHP
cd drivers/php
composer dump-autoload --no-dev
MALUDB_TEST_DSN="postgresql:///fieldtest?host=/var/run/postgresql" \
    php tests/smoke.php

# C
cd drivers/c
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
MALUDB_TEST_DSN="postgresql:///fieldtest?host=/var/run/postgresql" \
    ./build/maludb_smoke
```

Acceptance: every driver's smoke goes green; every driver's
example (`examples/01-ingest-to-replay.*`) prints the four-hit
pattern.

### F-6: Run broker smoke

```bash
cd services/mcp-broker
PYTHONPATH=src python3 -m unittest discover tests -v
```

Acceptance: 6/6 pass.

### F-7: Write `docs/field-test-alpha.md`

Capture timeline, every command, every surprise, every fix. The
template is `docs/field-test.md` (R1.0's). Write it as a chronological
record. Note any package conflicts, postgresql.conf edits needed,
permission surprises, etc.

Acceptance: A future operator can follow `docs/field-test-alpha.md`
end-to-end on a similar VM without consulting anyone.

## Exit criterion for Phase F

Every command in `docs/install.md` + `docs/getting-started.md` +
the four `examples/*.sql` runs clean on a fresh VM. Any discovered
gaps are tracked as fix tasks before Phase D begins.

---

# Phase P — Test-infrastructure polish *(small, ~20 min)*

Three small cleanups. Interleave with Phase F if convenient.

## Tasks

### P-1: CTest env passthrough

`drivers/c/CMakeLists.txt` currently captures `MALUDB_TEST_DSN`
at CMake-configure time via `$ENV{MALUDB_TEST_DSN}` and stores it
in `set_tests_properties(... ENVIRONMENT ...)`. That means if you
configure without the env var set, ctest can never see it.

Fix: remove the `ENVIRONMENT` line entirely. CTest passes the
parent environment through by default; the explicit override is
what's causing the breakage.

Acceptance:
```bash
MALUDB_TEST_DSN="..." ctest --test-dir build --output-on-failure
```
…goes green without re-configuring.

### P-2: PHPUnit-proper test run

Currently the PHP smoke runs via `tests/smoke.php` (a plain-PHP
runner) because PHPUnit ^11 requires `ext-dom` / `ext-xml`. After
`sudo apt install php-xml`, the proper PHPUnit path should work.

```bash
cd drivers/php
composer install   # this time without --ignore-platform-req
MALUDB_TEST_DSN="postgresql:///maludb_bench?host=/var/run/postgresql" \
    vendor/bin/phpunit
```

Acceptance: PHPUnit 3/3 pass. Keep `tests/smoke.php` — it's still
useful for the no-ext-dom path.

### P-3: `third_party/llama.cpp` submodule pointer

`git status` shows `modified: third_party/llama.cpp (untracked content)`.
Either commit the bump (`git add third_party/llama.cpp && git commit
-m "third_party: bump llama.cpp pointer"`) or document why the
working tree drift is intentional.

Acceptance: `git status -s` shows only the `docs/claude-log/*`
files (intentionally unstaged session logs).

## Exit criterion for Phase P

`git status -s` is clean except for session logs.

---

# Phase D — Distribution polish *(~2 h)*

Required for apt-repo upload. Without this, operators install via
`dpkg -i` and lose dependency resolution.

## Tasks

### D-1: Run `lintian` on the `.deb`s

```bash
sudo apt install lintian
cd /home/maludb/maludb-core
dpkg-buildpackage -us -uc -b -nc
lintian ../postgresql-*-maludb-core_*.deb ../maludb-mc2dbd_*.deb
```

Capture every E:/W: message. Likely candidates:
- `no-manual-page` for `maludb_mc2dbd`.
- `missing-debian-copyright-line` nits.
- `binary-without-manpage`.
- `embedded-script-includes-time-stamp` if any generated file has a
  timestamp.

Acceptance: full lintian output captured into a working list.

### D-2: Fix the lintian warnings

For each warning:
- **`no-manual-page`** — write a minimal `mc2dbd/man/maludb_mc2dbd.8`
  and install it via `debian/maludb-mc2dbd.install`.
- **copyright issues** — fix `debian/copyright` to DEP-5 strict.
- **embedded timestamps** — strip or normalise.

Acceptance: `lintian` returns zero E: messages and only suppressible
W: messages (override via `debian/maludb-mc2dbd.lintian-overrides`
with a documented rationale).

### D-3: Release SOP `docs/release.md`

Document the post-D-2 process:
1. Bump version in `debian/changelog`.
2. `dpkg-buildpackage -us -uc -b -nc` produces signed-by-build-host
   `.deb`s.
3. `dpkg-sig --sign builder ../*.deb` to sign with the release key.
4. `reprepro -b /srv/maludb-apt includedeb noble ../*.deb` to add
   to the apt-repo.
5. `apt-ftparchive` to refresh metadata.
6. Document the add-source line: `deb [signed-by=...] https://...
   noble main`.

Acceptance: a fresh operator can `apt install postgresql-17-maludb-core`
from the documented source on a clean VM.

### D-4: Tag v2.0.0-beta

Once Phase F + Phase D land, tag `v2.0.0-beta`. Update CHANGELOG.

## Exit criterion for Phase D

`lintian` clean; apt-repo upload documented; v2.0.0-beta tagged.

---

# Phase C — C SDK v0.2.0 *(~2 h)*

Round out `drivers/c/libmaludb` to match Python/Node/PHP surface.
Pure pattern repetition — same SQL contracts as the other drivers.

## Tasks

### C-1: Pool wrappers in `drivers/c/`

Add to `include/maludb.h`:

```c
MALUDB_API int64_t maludb_create_pool(
    maludb_t *m, const char *pool_name, const char *creation_kind,
    const char *task_objective, double confidence_floor,
    int max_member_count);

MALUDB_API int64_t maludb_pool_add_observation(
    maludb_t *m, int64_t pool_id, const char *payload_jsonb,
    double confidence, const char *provenance_jsonb);

MALUDB_API int64_t maludb_pool_promote_to_claim(
    maludb_t *m, int64_t member_id,
    const char *subject, const char *verb,
    const char *object_value, const char *statement_text);

MALUDB_API int maludb_pool_seal(
    maludb_t *m, int64_t pool_id, const char *reason);
```

Implementation: mirror `maludb_register_*` pattern in `src/maludb.c`.

Acceptance: one happy-path call per function in `tests/smoke.c`.

### C-2: Skill wrappers

```c
MALUDB_API int64_t maludb_register_skill(…);
MALUDB_API int64_t maludb_add_skill_state(…);
MALUDB_API int64_t maludb_add_skill_transition(…);
MALUDB_API int64_t maludb_begin_skill_execution(…);
MALUDB_API char   *maludb_step_skill_execution(…);  /* returns next state name; caller frees */
MALUDB_API int     maludb_abort_skill_execution(…);
MALUDB_API int     maludb_skill_emit_claim(…);
```

Acceptance: a 3-state skill machine drive-through in `smoke.c`.

### C-3: Node-sync wrappers

```c
MALUDB_API int64_t maludb_register_local_node(…);
MALUDB_API int64_t maludb_node_submit(…);
MALUDB_API char   *maludb_node_accept(…);  /* returns JSON result envelope */
MALUDB_API int     maludb_node_reject(…);
MALUDB_API int     maludb_revoke_local_node(…);
```

Acceptance: register → submit → accept → revoke round-trip in
`smoke.c`.

### C-4: Smoke test additions

Each new function gets one happy-path check in `tests/smoke.c`.
Re-run: `./build/maludb_smoke` should report `12+/12+` pass (was
6/6 in v0.1.0).

### C-5: Version bump + README update

- `drivers/c/CMakeLists.txt`: `VERSION 0.2.0`.
- `drivers/c/include/maludb.h`: `MALUDB_DRIVER_VERSION_MINOR 2` +
  `MALUDB_DRIVER_VERSION_STRING "0.2.0"`.
- `drivers/c/README.md`: extend the "API surface" table; mark v0.1.0
  items as "complete" and remove "Deferred to v0.2.0" note.

## Exit criterion for Phase C

C SDK exposes the full Python/Node/PHP method matrix; smoke
`12+/12+` pass.

---

# Phase B — Broker v0.2.0 + audit-loop closure *(~6 h, largest phase)*

Lands the broker features deferred from v0.1.0 plus the
audit-ingest closure into `malu$mc2db_invocation`.

## Tasks

### B-1: HTTP tool kind

In `services/mcp-broker/src/mcp_broker/tools.py`, add a new
dispatcher for `kind: "http"`. Use `urllib.request` (stdlib).
Spec shape:

```json
{
  "kind": "http",
  "spec": {
    "url": "https://api.example.com/v1/{{path}}",
    "method": "POST",
    "headers": {"Content-Type": "application/json"},
    "auth_token_file": "/etc/maludb/tokens/example.token",
    "body_template": "{\"query\":\"{{query}}\"}",
    "timeout_ms": 5000
  }
}
```

`{{var}}` substitution rules from shell kind apply identically.
`auth_token_file` is read at dispatch time, never logged. JSONL
audit on stderr: `tool`, `url_hash`, `status`, `duration_ms`,
`response_hash`.

Acceptance: smoke test that hits an `http.server` running in the
test fixture (stdlib `http.server.SimpleHTTPRequestHandler`).

### B-2: `mcp_proxy` tool kind

Spec shape:

```json
{
  "kind": "mcp_proxy",
  "spec": {
    "command": "/usr/local/bin/some-other-mcp-server",
    "argv": ["--config", "/etc/some.json"],
    "remote_tool_name": "search_docs",
    "timeout_ms": 10000
  }
}
```

Spawn the child broker as a subprocess, send `initialize` +
`tools/call` forwarding the parent caller's arguments. Subtlety:
the parent broker has already validated input against its own
schema; the child has its own. Pass arguments through unchanged.

Acceptance: smoke test that uses the same `mcp_broker` binary as
its own child to prove the protocol round-trip works.

### B-3: HTTPS / SSE transport

Behind a `--transport http://0.0.0.0:5330` (or `https://...` for
TLS) flag. Use stdlib `http.server` + `ssl`. Request flow:

- `POST /` carries one JSON-RPC request, returns one response.
- `GET /events` opens an SSE stream (for `tools/listChanged`
  notifications, which we don't emit in v0.2.0 but the shape
  needs to be there).

Don't add new dependencies. If stdlib isn't enough, defer to v0.3.0.

Acceptance: smoke test that drives the broker over HTTP curl
commands against `127.0.0.1:5330`.

### B-4: mc2dbd ingest of broker audit

Create `services/mc2dbd-broker-ingest/`:

- A small Python daemon (or a thread inside `mc2dbd`) that:
  1. Reads JSONL lines from the broker's stderr (file descriptor
     redirection, or a named pipe).
  2. Uses the `maludb` Python driver to
     `INSERT INTO malu$mc2db_invocation`.
  3. Tracks `argv_hash` / `output_hash` / `duration_ms` / `tool` /
     `ts` / `exit` per the broker's JSONL schema.
- A systemd unit that depends on the broker's unit (forthcoming
  from a `services/mcp-broker/systemd/` directory).
- A small SQL migration if needed (probably not — `malu$mc2db_invocation`
  already has the right columns).

Acceptance: run broker → invoke a tool → query
`malu$mc2db_invocation` and see the row.

### B-5: Smoke tests for each kind + an end-to-end ingest test

Extend `services/mcp-broker/tests/test_smoke.py`:

- One test per new tool kind.
- One test that asserts a `tools/call` is followed by a row landing
  in `malu$mc2db_invocation` (requires Python driver + a test DSN).

### B-6: Version bump + design doc update

- `services/mcp-broker/pyproject.toml`: `version = "0.2.0"`.
- `docs/mcp-broker-design.md`: move HTTP / mcp_proxy / HTTPS / live
  audit ingest out of "Deferred to v2" and into the v1 contract.

## Exit criterion for Phase B

Broker v0.2.0 supports all three tool kinds, both transports, and
every accepted `tools/call` lands a row in `malu$mc2db_invocation`
automatically.

---

# Phase X — Documentation polish *(~1 h, interleave anytime)*

## Tasks

### X-1: `docs/drivers.md`

Side-by-side method matrix across Python / Node.js / PHP / C, with
status (shipped / deferred) per language per method. Link from each
driver's README.

### X-2: `docs/architecture.md`

Single diagram (ASCII or Mermaid) showing:

```
LLM client / agent
       │ MCP
       ├──────────────► mc2dbd          → libpq → PostgreSQL → maludb_core (extension)
       │ stdio/HTTPS                                              ▲
       └──────────────► mcp-broker      → shell/HTTP/MCP child   │
                              │                                  │
                              └── JSONL audit ──► mc2dbd-broker-ingest ──┘
                                                       (Python driver)

Direct callers:
       drivers/{python,nodejs,php,c} ── libpq ──► PostgreSQL → maludb_core
```

Plus the layered identity model (maludb_memory_{admin,executor,
auditor,dba} + maludb_llm_*).

### X-3: Update top-level README

Link the new doc pages from the "Documents" section.

## Exit criterion for Phase X

A new contributor lands on the README and can find the right doc
for any question without grepping.

---

# Session-resume checklist

When you start the next session, verify in this order:

1. `git log --oneline -1` shows `2f457a9` (the v2.0.0-alpha.4
   release-notes commit) or further ahead.
2. `git describe --tags --abbrev=0` shows `v2.0.0-alpha.4`.
3. `make installcheck` against PG 17 still reports 51/51.
4. The four driver smoke tests still pass.
5. `git status -s` shows only `docs/claude-log/*` (your session
   logs).

If any of those fail, stop and investigate before starting a new
phase. The roadmap above assumes the alpha is healthy.

## Suggested first-session-after-alpha schedule

If you have ~3 hours, do:

1. **Phase F** in full (~2 h).
2. **Phase P** quick cleanup (~20 min).
3. Adopt any field-test fixes and tag `v2.0.0-alpha.5`.

If you have ~2 hours, do **Phase F** only and tag the friction-fix
results as `v2.0.0-alpha.5`.

If you have ~30 minutes, do **Phase P** only.

## When in doubt

Ask before:
- Pushing to `origin`.
- Force-pushing anything.
- Bumping the extension major version (would be `1.0.0` in the
  migration chain — that's an explicit "schema-stability commitment"
  signal).
- Deleting any `expected/*.out` file.
- Touching `white-paper.md`.

When you need a sanity check, the bench DB at `maludb_bench` is
the canonical playground — every example and driver smoke test
runs against it.

---

*Compiled 2026-05-13 at `v2.0.0-alpha.4`.*
