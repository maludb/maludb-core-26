# Ubuntu 26.04 + PostgreSQL 18 — Upgrade Feasibility & Level of Effort

Draft: 2026-05-14

This document analyzes the work required to add **PostgreSQL 18** as a fully-supported runtime and **Ubuntu 26.04 LTS** as a fully-supported host OS for MaluDB. It is the operational companion to [`requirements.md`](requirements.md) §2 (Target Platform) and the V3 acceptance contract.

The two upgrades are **partially independent but interact**. PG 18 is already declared as a CI target (allowed-fail) on the existing Ubuntu 24.04 runners; Ubuntu 26.04 introduces a new codename plus a new default toolchain. Each is analyzed on its own first, then the cross-product matrix is summarized.

---

## 1. Baseline (what's already in place at `v3.0.0-rc.1`)

| Surface | Current state |
|---|---|
| CI matrix | `runs-on: ubuntu-24.04` × `pg ∈ {16, 17, 18}`. PG 18 is `continue-on-error: true` (allowed-fail). |
| Debian packaging | `debian/control` defines `postgresql-16-maludb-core`, `postgresql-17-maludb-core`, `postgresql-18-maludb-core` packages. `debian/pgversions` lists `16, 17, 18`. |
| Build-Depends | `postgresql-server-dev-16`, `postgresql-server-dev-17`, `postgresql-server-dev-18`, plus `postgresql-server-dev-all (>= 217~)`. |
| PGDG repo line | Hardcoded to `noble-pgdg` (Ubuntu 24.04 codename) in 8 locations across `.github/workflows/ci.yml`, `scripts/install-dev-env.sh`, `scripts/maludb-bootstrap`. |
| OS version checks | `scripts/maludb-bootstrap` and `scripts/maludb-fieldtest` **explicitly reject** any host that is not `ID=ubuntu` + `VERSION_ID=24.04`. |
| Source C macros | `src/*.c` and `mc2dbd/src/*.c` contain **zero** `PG_VERSION_NUM` conditionals — the C code is currently version-agnostic across PG 16/17/18. |
| Required extensions | `maludb_core.control` `requires = 'vector, btree_gist, pg_trgm, pgcrypto'`. Runtime deps (not in `requires`): `pgaudit`, `pg_partman`. |
| docs/install.md | References `noble` codename explicitly. |
| 20260514-status.md | States "PostgreSQL 17 from PGDG; PG 16/18 in CI matrix" and "Ubuntu 24.04 LTS, x86_64 + arm64". |
| `requirements.md` §10 open decisions | "Whether `extension_control_path` (PG 18) becomes a hard requirement (would bump min PG to 18)" — still open. |
| `CLAUDE.md` "Things in flux to watch" | Notes PG 18 GA introduces `extension_control_path` and OAuth; "decision deferred". Apache AGE on PG 18 — "track readiness" (AGE is opportunistic, not required). |

This baseline matters: the gap between "already declared" and "actually supported" is smaller than it looks for PG 18, and larger than it looks for Ubuntu 26.04.

---

## 2. PostgreSQL 18 support — what remains

### 2.1 Already done
- C extension code compiles under PG 18 headers (no version conditionals to revisit).
- `pg_regress` harness, Makefile, and PGXS plumbing are version-agnostic.
- `.deb` skeleton for `postgresql-18-maludb-core` is in `debian/control` with the right dependency declarations.
- CI runs PG 18 on every push (currently allowed to fail).

### 2.2 Real remaining work

| Item | Effort | Notes |
|---|---|---|
| Validate PGDG `postgresql-18-pgvector`, `postgresql-18-pgaudit`, `postgresql-18-partman` packages on `noble` | ~½ day | These are the runtime deps that the v3 services need. If any is missing/broken, work blocks. |
| Run full 66-case pg_regress under PG 18 | ~½ day | PG 18 commonly changes EXPLAIN output formatting, error message wording, deterministic seed values, and parallel-query plans. Some `expected/*.out` files will diff; each diff has to be inspected to confirm it's PG-version drift, not a real regression. |
| Run `mc2dbd` (7 tools), `maludb-restd` (7 routes), `maludb-realtimed` (4 cases), `maludb` CLI (11 cases), libmaludb v0.2 (12 cases) service smokes under PG 18 | ~½ day | These are catalog-driven and should be insensitive to PG version, but the auth_token / vector_chunk / event tables get touched. |
| Verify `pg_buildext` produces a working `postgresql-18-maludb-core_X.Y.Z-1_amd64.deb` | ~½ day | Needs an Ubuntu 24.04 build host with `postgresql-server-dev-18` installed. |
| Flip CI `continue-on-error: ${{ matrix.pg == '18' }}` to `false` | minutes | Once everything above is green. |
| Field-test on a fresh Ubuntu 24.04 + PG 18 host | ~½ day | Mirrors the V3 RC field test, just on PG 18. |
| `requirements.md` §10 decision: keep PG 17 as the baseline minimum, or bump to PG 18 | minutes | Recommend: **keep PG 17 as minimum.** Treat PG 18 as a supported runtime, not a required one. `extension_control_path` is a nice-to-have, not load-bearing for V3 or V4. |
| `requirements.md` §2 + `README.md` + `20260514-status.md`: update "PG 18 in CI (allowed-fail)" → "PG 16/17/18 fully supported" | ~½ hour | Doc reconciliation. |
| Optional follow-up: adopt `extension_control_path` for V3-ENV-01 preview environments | ~½ day, gated by PG 18 minimum bump | Out of scope if PG 17 stays the minimum. |

### 2.3 Risks specific to PG 18

1. **Apache AGE on PG 18.** AGE is currently used opportunistically (recursive CTEs are preferred). If a customer ever flips on the AGE path, AGE must support PG 18; PGDG packaging for AGE on PG 18 is uncertain. Mitigation: keep the recursive-CTE fallback as the default; document AGE-on-PG-18 as an operator opt-in once upstream packages land.
2. **`pgcrypto` behavior.** PG 18 may tighten defaults around `pgp_sym_encrypt` (V3-SECRET-01 depends on this). Worth a focused test on the secret-store regression cases.
3. **Default toolchain on the build host.** The PG 18 server headers compiled under gcc-13 / Clang-18 on Ubuntu 24.04 should be fine; under a newer toolchain on 26.04 it's a separate question (see §3).

### 2.4 PG 18 effort estimate

**1–2 focused days** for a developer who already has Ubuntu 24.04 + a build cluster ready. Mostly debugging `expected/*.out` drift and confirming the PGDG package set is complete. Genuine risk only if AGE-on-PG-18 becomes load-bearing (it isn't in current scope).

---

## 3. Ubuntu 26.04 support — what remains

### 3.1 Context

Ubuntu 26.04 LTS is the next LTS after 24.04 (Ubuntu LTS cadence: April of even-numbered years). At the time of writing (2026-05-14) it is the recommended Ubuntu version. The codename string used by PGDG and apt sources for 26.04 needs to be verified at the time of upgrade work — this document refers to it generically as **`<26.04-codename>-pgdg`** because the exact codename is not authoritatively known here. Substituting the actual codename is the first line of the upgrade work.

### 3.2 Already done

- The C code is OS-agnostic; nothing in `src/` knows what Ubuntu version it's running on.
- PGXS + standard apt tooling work the same way across Ubuntu releases.
- Python services (`maludb-restd`, `maludb-realtimed`, `mcp-broker`, `maludb-pageindexd` planned for V4) are stdlib-Python + thin third-party deps (`psycopg`, `litellm`, `pypdf`). These should work on the Python version Ubuntu 26.04 ships, but require validation.

### 3.3 Real remaining work

| Item | Effort | Notes |
|---|---|---|
| Confirm Ubuntu 26.04 codename + verify PGDG `<26.04-codename>-pgdg` apt repository exists and ships `postgresql-{16,17,18}` + dependent extension packages (`pgvector`, `pgaudit`, `partman`) | ~½ day | **External-dependency gate.** If PGDG hasn't published 26.04 packages yet, the upgrade is blocked on upstream. Historically PGDG adds new Ubuntu LTS support within weeks of release. |
| Parameterize the hardcoded `noble` references | ~½ day | 8 occurrences in `.github/workflows/ci.yml`; 1 each in `scripts/install-dev-env.sh`, `scripts/maludb-bootstrap`, `docs/install.md`. Replace with `$(. /etc/os-release && echo "${VERSION_CODENAME}-pgdg")` so the PGDG line auto-resolves per host. |
| Widen the `VERSION_ID` gate in `scripts/maludb-bootstrap` and `scripts/maludb-fieldtest` | minutes | Change `[ "${VERSION_ID:-}" = "24.04" ]` to `[ "${VERSION_ID:-}" = "24.04" ] \|\| [ "${VERSION_ID:-}" = "26.04" ]`. Both scripts have a single check each. |
| Add `runs-on: ubuntu-26.04` to the CI matrix once available | ~1 day | GitHub Actions historically rolls out new LTS runners weeks-to-months after the Ubuntu release. The CI matrix grows from PG×3 = 3 jobs to PG×3 × OS×2 = 6 jobs per push (plus sanitizer + static-analysis runs). Cost approximately doubles. |
| Toolchain drift: confirm gcc / clang / llvm versions on 26.04 don't introduce new warnings, behavior changes, or sanitizer flag breakage | ~1–2 days | 24.04 ships gcc 13, Clang 18, LLVM 18. 26.04 likely ships newer majors (gcc 14 or 15, Clang 19 or 20). New compiler majors usually surface new `-Wall` / `-Wextra` warnings — these need triage (suppress, fix, or document). ASan/UBSan flag compatibility is usually fine but worth a smoke. |
| `CLAUDE.md` "Clang 18 for sanitizer" reference + Makefile `scan-build-18` / `clang-tidy-18` references | ~½ day | Either pin to the specific tool version (`clang-18`) installable on both 24.04 and 26.04, or parameterize via `CLANG_MAJOR=18` env var. Recommend pin-via-apt — `clang-18` should be available in 26.04's archive even if not the default. |
| `pg_buildext` deb packaging under 26.04 | ~½ day | The `.deb` output should install on either Ubuntu LTS, but should be built and smoke-tested on each. |
| Python service compatibility on 26.04's Python (likely 3.13 or 3.14) | ~½ day | All four services use stdlib + `psycopg` + `litellm` + (for V4) `pypdf`. Run smokes under the new Python; address any deprecation warnings. |
| Service unit-file paths under systemd on 26.04 | ~½ hour | `/lib/systemd/system/` vs `/usr/lib/systemd/system/` has shifted across releases; the merged-`/usr` migration in 24.04 should already cover this, but worth confirming. |
| Field-test on a fresh Ubuntu 26.04 host | ~½ day | Mirrors the V3 RC field test. |
| `docs/install.md`, `README.md`, `CLAUDE.md`, `AGENTS.md`, `20260514-status.md`: update "Ubuntu 24.04 LTS" → "Ubuntu 24.04 LTS, Ubuntu 26.04 LTS" | ~½ hour | Doc reconciliation. |

### 3.4 Risks specific to Ubuntu 26.04

1. **PGDG availability.** This is the hard external gate. Without PGDG packages for the 26.04 codename, no MaluDB install path works on 26.04. Mitigation: monitor `https://apt.postgresql.org` for the new codename; do not begin Ubuntu 26.04 work until PGDG is ready.
2. **GitHub Actions `ubuntu-26.04` runner availability.** GitHub typically rolls these out on a delay after the Ubuntu LTS release. Until then, CI cannot exercise 26.04. Mitigation: a manually-provisioned Ubuntu 26.04 VM can validate locally; CI follows.
3. **Compiler-driven test diffs.** New gcc/clang majors occasionally change `-Wuninitialized` analysis, float formatting, or `printf` format-string warnings. Each warning needs triage; sanitizer suppression files may need updates.
4. **`libicu` major version bump.** PG's collation handling is sensitive to `libicu` versions. A new `libicu` major on 26.04 can change collation outputs and break `expected/*.out`. Existing pg_regress test fixtures that rely on `text` ordering should be checked — there are a handful in the 66-case suite.
5. **`debian/control` Standards-Version drift.** Currently `Standards-Version: 4.6.2`. Lintian under a newer `lintian` on 26.04 may demand a bump; non-blocking but worth a sweep.
6. **Apache AGE on 26.04.** Same uncertainty as PG 18 — track readiness.

### 3.5 Ubuntu 26.04 effort estimate

**3–5 focused days** assuming PGDG packages exist and the GitHub Actions runner is available. **Up to 7 days** if toolchain drift surfaces a non-trivial number of new warnings or if `libicu` causes pg_regress diffs that need triage rather than mechanical absorption.

If PGDG packages or the GHA runner aren't ready, the upgrade is blocked on upstream — that's wall-clock time, not effort.

---

## 4. Cross-product matrix

The expanded support surface is the cross-product of supported OS × supported PG major:

| Host | PG 16 | PG 17 | PG 18 |
|---|---|---|---|
| Ubuntu 24.04 | ✅ supported (current baseline) | ✅ **blessed** (default) | ⚠️ CI allowed-fail today → target: ✅ |
| Ubuntu 26.04 | ⏳ not yet | ⏳ not yet | ⏳ not yet → target: ✅ |

Recommended **target post-upgrade** matrix:

| Host | PG 16 | PG 17 | PG 18 |
|---|---|---|---|
| Ubuntu 24.04 | ✅ | ✅ **blessed** | ✅ |
| Ubuntu 26.04 | ✅ | ✅ | ✅ **blessed** (recommend as default once stable) |

CI matrix becomes `os × pg = 2 × 3 = 6` jobs per push (currently 3). Sanitizer + static-analysis jobs stay on one OS+PG combo (recommend Ubuntu 24.04 + PG 17 to keep the analysis baseline stable across the transition).

---

## 5. Recommended sequencing

**Decision (2026-05-14): defer all platform upgrades until V4 PageIndex/ChatIndex is complete and fully tested.** Both PG 18 full-support work and Ubuntu 26.04 support work begin **after `v4.0.0` GA**, not after `v3.0.0` GA.

Rationale: V3 RC field-test → V4 implementation → V4 RC field-test is a coherent product arc on the existing Ubuntu 24.04 + PG 17 baseline. The C code is version-agnostic and the platform-track work is purely additive, so deferring it past V4 carries no doctrinal or design cost. Upstream readiness (PGDG packaging for the 26.04 codename, GHA `ubuntu-26.04` runner availability) is more likely to be settled by the time V4 GA ships, reducing the chance the upgrade work blocks on external dependencies.

### Post-V4 plan (deferred — do not start until v4.0.0 is GA + field-tested)

1. **`PLAT-PG18-01` — PG 18 fully supported on Ubuntu 24.04.** Flip CI from allowed-fail to required. Ship as a `v4.0.x` patch release or `v4.1.0` once green.
2. **`PLAT-UBUNTU2604-01` — Parameterize hardcoded `noble` references, widen OS gates, validate PGDG availability.** Ship as a separate patch release.
3. **`PLAT-UBUNTU2604-02` — Add `ubuntu-26.04` to CI matrix when GitHub Actions runner is available; full field-test on 26.04.** Ship once green.

Total: ~1 week of focused effort across the three tickets, gated on PGDG + GHA upstream readiness. Combine into a single release only if upstream readiness aligns naturally; otherwise sequence as listed.

### Alternative sequences (rejected for current planning cycle)

- **Sequence A** (PG 18 first, then Ubuntu 26.04, *before* V4 starts) — rejected per the decision above.
- **Sequence B** (combined platform release *before* V4 starts) — rejected per the decision above.

---

## 6. Open questions — decisions of record (2026-05-14)

1. **PG minimum stays at 17.** ✅ **Decided.** Do not bump to PG 18 as the minimum. PG 18 is added as a supported runtime; PG 17 remains the blessed default. `requirements.md` §2 baseline language unchanged. `requirements.md` §10 entry on `extension_control_path` (PG 18) → `min PG to 18` can be closed as "rejected for now."
2. **Ubuntu LTS support window policy** — ⏳ **Deferred.** Will be settled at the time `PLAT-UBUNTU2604-*` tickets are picked up, post-`v4.0.0` GA. Working assumption until then: support the current and previous LTS (24.04 + 26.04 once both ship), drop the older one when the next LTS lands.
3. **Non-LTS Ubuntu policy (24.10, 25.04, 25.10)** — ⏳ **Deferred** alongside (2). Working assumption: best-effort, no CI matrix entry.
4. **PG 16 stays supported alongside 17 and 18.** ✅ Unchanged from current `requirements.md` §2. PG 16 reaches PostgreSQL community EOL in November 2028; no rush.
5. **Apache AGE-on-PG18 as a hard gate** — ✅ **Decided: no.** AGE is opportunistic (recursive CTEs are the default path). AGE-on-PG-18 status stays a `requirements.md` §10 watch item, not a blocker.

---

## 7. Verdict and total LoE

- **PG 18 full support: 1–2 days of focused effort.** Almost everything is in place; the gap is validation, expected-output absorption, and a CI flag flip.
- **Ubuntu 26.04 full support: 3–5 days of focused effort, plus upstream wait time** for PGDG packages and GHA runner availability. The work itself is mechanical (codename parameterization, OS-gate widening, toolchain drift triage); the timeline is gated on external dependencies.
- **Combined: about 1 working week** if both upstream gates are clear.
- **Risk profile: low.** Both upgrades are additive — they don't change the memory model, doctrine, or shipped surface. The C code is version-agnostic by accident, which removes the largest class of porting risk.
- **Decided timing (2026-05-14): after `v4.0.0` GA and full V4 field-test,** not before V4 starts. PG 17 remains the minimum; PG 18 is additive. Ubuntu LTS / non-LTS support policy will be settled when the platform tickets are picked up.

These are platform-track tickets, not V4 PageIndex tickets. They should be sequenced into the `requirements.md` §9 stage chain with their own migration-free stage numbers (no schema impact) and tagged independently of the V4 PageIndex/ChatIndex track.

---

*Update this document when PGDG and GitHub Actions confirm Ubuntu 26.04 readiness, when the actual 26.04 codename is known, and when a decision is made on Sequence A vs B vs C.*
