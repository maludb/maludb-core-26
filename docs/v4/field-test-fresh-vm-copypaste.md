# V4 Fresh-VM Field Test — Copy-Paste Commands

Every command in this file is on a **single line**. Copy a line,
paste it into the VM shell, run it. No line continuations. This
file is self-contained — paste straight through §1 → §13 on a
freshly-provisioned Ubuntu 24.04 host and you land on a tagged
`v4.0.0` GA.

---

## §1. OS prerequisites

```bash
sudo apt-get update
```

```bash
sudo apt-get install -y build-essential pkg-config bison flex libicu-dev libssl-dev libreadline-dev zlib1g-dev liblz4-dev libzstd-dev libxml2-dev libmicrohttpd-dev libjansson-dev libgnutls28-dev libcurl4-openssl-dev jq curl git python3 python3-psycopg python3-pytest python3-pypdf cmake clang-19 lcov
```

The V4-specific delta is `python3-pypdf` — the maludb-pageindexd
parser unittests import it directly. Everything else is the same
set the V3 gate used.

---

## §2. Add the PGDG apt repository

```bash
sudo install -d /usr/share/postgresql-common/pgdg
```

```bash
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
```

```bash
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
```

```bash
sudo apt-get update
```

### §2 verification

```bash
cat /etc/apt/sources.list.d/pgdg.list
```

Expect a single line containing `noble-pgdg main`.

```bash
apt-cache policy postgresql-17 | head -10
```

Expect `Candidate:` to point at a `pgdg24.04` version (e.g.
`17.10-1.pgdg24.04+1`). If `Candidate:` is `(none)`, §2 didn't take
— re-run the §2 commands.

---

## §3. Install PostgreSQL 17 + required extensions

```bash
sudo apt-get install -y postgresql-17 postgresql-server-dev-17 postgresql-17-pgvector postgresql-17-pgaudit postgresql-17-partman
```

### §3 verification

```bash
/usr/lib/postgresql/17/bin/pg_config --version
```

```bash
sudo systemctl is-active postgresql
```

```bash
psql -V
```

Expect `PostgreSQL 17.x`, `active`, and `psql (PostgreSQL) 17.x`.

---

## §4. Clone the repo at the V4 RC tag

```bash
git clone https://github.com/maludb/maludb-core.git
```

```bash
cd maludb-core
```

```bash
git checkout v4.0.0-rc.1
```

```bash
git log -1 --oneline
```

Expect HEAD to be detached at `v4.0.0-rc.1` (commit subject begins
with "V4 rc.1").

---

## §5. Build + install the extension

```bash
export PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

```bash
make clean
```

```bash
make PG_CONFIG="$PG_CONFIG"
```

```bash
sudo make install PG_CONFIG="$PG_CONFIG"
```

### §5 verification

```bash
grep default_version /usr/share/postgresql/17/extension/maludb_core.control
```

Expect `default_version = '0.71.0'`.

```bash
ls /usr/share/postgresql/17/extension/maludb_core--*.sql | wc -l
```

Expect 71 (the initial `0.1.0.sql` + 70 forward migrations from
`0.1.0 → 0.2.0` through `0.70.0 → 0.71.0`).

```bash
ls /usr/share/postgresql/17/extension/maludb_core--0.70.0--0.71.0.sql
```

Expect the file to exist — that's the alpha.6 V4-REST-01 migration.
If missing, §5 didn't take.

---

## §6. Bootstrap the cluster

```bash
sudo scripts/maludb-bootstrap
```

This wires `pgaudit`, `pg_stat_statements`, and any other
preload-libraries the extension needs into
`/etc/postgresql/17/main/postgresql.conf` via `pg_conftool` and
restarts PG.

### §6 verification

```bash
sudo systemctl is-active postgresql
```

Expect `active`.

---

## §7. Make your user a PostgreSQL superuser

```bash
sudo -u postgres psql -c "CREATE USER \"$USER\" SUPERUSER;"
```

If that errors with `role "..." already exists`, run instead:

```bash
sudo -u postgres psql -c "ALTER USER \"$USER\" WITH SUPERUSER;"
```

---

## §8. Python environment (only if `python3-psycopg` is unavailable)

Skip this section if the following works:

```bash
python3 -c "import psycopg; print(psycopg.__version__)"
```

Otherwise, install via a venv:

```bash
sudo apt-get install -y python3-venv
```

```bash
python3 -m venv /tmp/maludb-ft-venv
```

```bash
source /tmp/maludb-ft-venv/bin/activate
```

```bash
pip install "psycopg[binary]>=3.1" pytest pypdf
```

If you use the venv, every Python suite below must be run from a
shell where the venv is still activated.

---

## §9. Run pg_regress (primary V4 gate)

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

**Expect the last line:** `# All 74 tests passed.`

If any test fails, the per-test diff lives in
`results/<name>.out.diff`. Capture it for the report and stop —
this is the GA gate.

---

## §10. Run the V4 service / CLI / SDK smokes

Run these immediately after §9 so `contrib_regression` is still
populated.

### §10.1 maludb-pageindexd parsers (V4-PARSER-01)

```bash
cd services/maludb-pageindexd
```

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -t . -v
```

Expect `Ran 18 tests` with `OK (skipped=4)`. The 4 skipped tests
are the live-DB builder tests gated behind
`MALUDB_PAGEINDEXD_TEST_DB=1`; we don't run them on the GA gate.

### §10.2 maludb-restd

```bash
cd ../maludb-restd
```

```bash
MALUDB_RESTD_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect `7 passed`.

### §10.3 maludb-realtimed

```bash
cd ../maludb-realtimed
```

```bash
MALUDB_REALTIMED_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect `4 passed`.

### §10.4 maludb CLI

```bash
cd ../../cli/maludb
```

```bash
MALUDB_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect `11 passed`. The new `maludb pageindex` and `maludb chatindex`
subcommand families are exercised end-to-end by the V4 orchestration
runner in §11.

### §10.5 libmaludb (C SDK)

```bash
cd ../../drivers/c
```

```bash
cmake -B build -S .
```

```bash
cmake --build build
```

```bash
MALUDB_TEST_DSN="dbname=contrib_regression" ctest --test-dir build --output-on-failure
```

Expect both `smoke` and `smoke_v02` to pass (V3 SDK round-trip
plus pool/skill/node). The new V4 C wrappers
(`maludb_pageindex_build`, `_supersede`, `_ask`,
`maludb_chatindex_build`, `_append`, `_ask`) are declared in
`drivers/c/include/maludb.h` and exercised by §11.

```bash
cd ../..
```

---

## §11. Run the V4 end-to-end orchestration

```bash
MALUDB_FT_DB=contrib_regression scripts/maludb-fieldtest-v4
```

**Expect the last line:** `V4 field-test: GREEN` (and `PASS=28
FAIL=0` above it).

### §11 capture for the sign-off

```bash
MALUDB_FT_DB=contrib_regression scripts/maludb-fieldtest-v4 --json > /tmp/v4-fieldtest-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).json
```

```bash
ls -la /tmp/v4-fieldtest-*.json
```

```bash
jq '.pass, .fail' /tmp/v4-fieldtest-*.json
```

Expect `28` then `0`.

---

## §12. Run the V4 bench

```bash
bench/v4/run-bench
```

Expect recall = 1.00 on each tree and p95 ≤ ~15 ms on a modern VM.
The GA gate is recall ≥ 0.80 on each tree under the deterministic
`overlap` strategy.

### §12 capture for the sign-off

```bash
bench/v4/run-bench --json > /tmp/v4-bench-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).json
```

```bash
jq '.page_index.recall, .chat_index.recall' /tmp/v4-bench-*.json
```

Expect `1` (or at minimum `0.8`) on each line.

---

## §13. Doc consistency

```bash
scripts/maludb-check-doc-consistency
```

Expect:

```
maludb-check-doc-consistency: OK
  default_version = 0.71.0 (control, README, user-manual all agree)
  release tag     = v4.0.0-rc.1 (README, CHANGELOG, user-manual all agree)
  PG majors       = 16,17,18 (manual) / 16,17,18 (CI)
  services        = maludb_modeld, maludb_mc2dbd, mcp-broker
  SDKs            = C, Python, Node.js, PHP
```

---

## §14. Sign-off

```bash
HOST=$(hostname)
```

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
```

```bash
REPORT="docs/v4/field-test-fresh-vm-${HOST}-${TS}.md"
```

```bash
cp docs/v4/field-test-fresh-vm-template.md "$REPORT"
```

```bash
echo "$REPORT"
```

Then edit `$REPORT`:

1. Replace the **Host** table with this VM's hostname, OS version
   (`lsb_release -a`), PG version (from §3 verification), `HEAD`
   sha (`git log -1 --oneline`), and today's UTC date.
2. Fill the **Suites** table with each suite's PASS count from
   §9–§12.
3. Fill the **V4 end-to-end orchestration** table with the 28
   per-stage assertions — paste the JSON from §11 if you want a
   machine-readable copy alongside.
4. Fill the **V4 bench baselines** table from the §12 JSON.
5. Flip **acceptance criterion #2** to `PASS`, citing this VM's
   hostname.
6. List any first-run traps you hit (see §16 troubleshooting
   below); if none, write "none observed".
7. Write the Verdict block.

```bash
git checkout -b ga-gate-v4-${HOST}-${TS}
```

```bash
git add "$REPORT"
```

```bash
git commit -m "V4 GA gate: fresh-VM field-test on ${HOST} (${TS})"
```

```bash
git push -u origin "ga-gate-v4-${HOST}-${TS}"
```

### §14.1 Open the GA-gate pull request

After the push, the remote prints a "Create new pull request"
URL. If you missed it, find it manually:

```bash
echo "https://github.com/maludb/maludb-core/compare/main...ga-gate-v4-${HOST}-${TS}"
```

Open that URL in a browser.

**PR title (paste verbatim):**

```
V4 GA gate: fresh-VM field-test on <HOST>
```

…with `<HOST>` substituted (the literal hostname, e.g.
`host01`).

**PR description (paste this template, then fill the bracketed
spots):**

```markdown
## What this PR is

V4 fresh-VM GA gate. Adds the field-test sign-off report for a
clean Ubuntu 24.04 host running the `v4.0.0-rc.1` baseline.

| | |
|---|---|
| VM hostname    | `<HOST>` |
| Field-test UTC | `<TS>` |
| HEAD at test   | `<git log -1 --oneline output>` |
| Report path    | `docs/v4/field-test-fresh-vm-<HOST>-<TS>.md` |

## Suites green on this VM

- `make installcheck` — **74/74**
- `services/maludb-pageindexd/tests` — **14 passed, 4 skipped**
  (live-DB builder tests gated)
- `services/maludb-restd/tests` — **7/7**
- `services/maludb-realtimed/tests` — **4/4**
- `cli/maludb/tests` — **11/11**
- `drivers/c` — **smoke + smoke_v02 PASS**
- `scripts/maludb-fieldtest-v4` — **28/28**
- `bench/v4/run-bench` — **recall = 1.00 each tree, p95 ≤ ?? ms**
- `scripts/maludb-check-doc-consistency` — **green**

## Post-RC scaffolding in scope (if any)

If `main` advanced past `v4.0.0-rc.1` before this run, list the
non-functional commits below; otherwise delete this section.

| Commit | Subject | Why it's in scope |
|---|---|---|
| `<sha>` | `<subject>` | `<rationale>` |

## First-run traps observed

Either "none observed" or the bullet list from the report's
Traps section.

## Artefacts (paste below this line)

Two captured JSON blobs — paste each in its own fenced block.
Don't link to `/tmp/…` paths; the files won't survive the VM.

### `scripts/maludb-fieldtest-v4 --json`

<paste contents of /tmp/v4-fieldtest-<HOST>-<TS>.json>

### `bench/v4/run-bench --json`

<paste contents of /tmp/v4-bench-<HOST>-<TS>.json>

## Verdict

V4 is **FIELD-TEST GREEN** on `<HOST>` at HEAD `<sha>` over the
`v4.0.0-rc.1` baseline. All 11 V4 acceptance criteria PASS (or
PASS-deferred per plan §10).

**GA approved.** Tag `v4.0.0` to be cut from `main` at HEAD
≥ `<sha>` after merge — see `docs/v4/field-test-fresh-vm-copypaste.md`
§15.
```

### §14.2 Paste the JSON artefacts

The two `--json` captures from §11.3 and §12.3 live on the VM at
`/tmp/v4-fieldtest-<HOST>-<TS>.json` and
`/tmp/v4-bench-<HOST>-<TS>.json`. **They will not survive a VM
reboot** — paste them into the PR description NOW, not later.

Easiest way: on the VM, print each file to the terminal and
copy-paste straight into the PR body inside the two fenced
blocks the template reserves for them:

```bash
cat /tmp/v4-fieldtest-*.json
```

```bash
cat /tmp/v4-bench-*.json
```

If the JSON is too long for the PR description (Gitea's body
field is generous but not unlimited), attach the files as
release-asset uploads instead:

* Click **"Files"** in the Gitea PR view → **"Add file"** →
  **"Upload file"**.
* Upload both JSON files to `docs/v4/artefacts/` so they're
  versioned with the report. Add them to the same branch
  (`ga-gate-v4-<HOST>-<TS>`) before merge:

  ```bash
  mkdir -p docs/v4/artefacts
  ```

  ```bash
  cp /tmp/v4-fieldtest-*.json /tmp/v4-bench-*.json docs/v4/artefacts/
  ```

  ```bash
  git add docs/v4/artefacts/v4-*.json
  ```

  ```bash
  git commit --amend --no-edit
  ```

  ```bash
  git push --force-with-lease origin "ga-gate-v4-${HOST}-${TS}"
  ```

  (The `--force-with-lease` is safe here because the branch is
  brand-new and only your commit is on it. Don't use this on any
  other branch.)

### §14.3 Review checklist

Before merging, the reviewer (or you, self-reviewing — same
checklist either way) should confirm every line:

- [ ] PR diff contains **exactly one** new file:
      `docs/v4/field-test-fresh-vm-<HOST>-<TS>.md`. If artefacts
      were committed via §14.2's force-amend path, also exactly
      two files under `docs/v4/artefacts/`. **No other files.**
- [ ] The report's Host table identifies a freshly-provisioned
      Ubuntu 24.04 host with no prior MaluDB state. The
      `Tag under test` row reads `v4.0.0-rc.1`.
- [ ] Every row in the Suites table is **PASS** with the
      expected count (74/74, 14/14 (4 skipped), 7/7, 4/4, 11/11,
      C SDK PASS, 28/28, recall ≥ 0.80 each tree, doc-consistency
      green).
- [ ] All 28 rows in the V4 end-to-end orchestration table are
      **PASS**. Spot-check against the pasted
      `maludb-fieldtest-v4 --json` artefact.
- [ ] V4 bench baselines table shows recall = 1.00 (or at minimum
      ≥ 0.80) on each tree and p95 < 100 ms.
- [ ] Acceptance criterion #2 ("fresh Ubuntu 24.04 host") is
      flipped to **PASS** and cites this VM's hostname.
- [ ] Traps section is either "none observed" or each entry has
      a clear (failure mode, recovery, root-cause patch target).
- [ ] Verdict reads **FIELD-TEST GREEN** and **GA approved**.

If any box is unchecked, **do not merge**. Fix on the
`ga-gate-v4-<HOST>-<TS>` branch and push again.

### §14.4 Merge

In the Gitea PR view, choose **"Create merge commit"** (NOT
"Squash" — we want the GA gate as its own discrete commit on
`main`'s history). The commit message Gitea proposes is fine
verbatim (`Merge pull request 'V4 GA gate: …' from
ga-gate-v4-… into main`).

Click **Merge Pull Request**.

After merge, on whichever machine you'll run §15 from:

```bash
git checkout main
```

```bash
git pull
```

```bash
git branch -d ga-gate-v4-${HOST}-${TS}
```

```bash
git push origin --delete ga-gate-v4-${HOST}-${TS}
```

The branch is gone; the report (and artefacts if you committed
them) live on `main`. You're ready for §15.

---

## §15. Cut the GA tag

After the PR from §14 merges, run §15 from the build host or this
VM — wherever you have push access to the remote. Do **not** tag
from a fork or a stale checkout.

### §15.1 Pre-flight checks

Switch to `main` and pull the merge commit:

```bash
git checkout main
```

```bash
git pull
```

Confirm the sign-off report is at `HEAD` and the working tree is
clean (no leftover edits from §14):

```bash
git status
```

Expect `On branch main` and `nothing to commit, working tree clean`.
If `git status` shows anything in red, stop — investigate before
tagging.

Confirm the doc-consistency gate is still green (this is the
single cheapest "did anything drift" check):

```bash
scripts/maludb-check-doc-consistency
```

Expect the same output you saw in §13. If it now reports a
mismatch (very unlikely, but possible if the merge raced another
PR), fix the drift on a follow-up commit before tagging.

Confirm the rc.1 → main range is what you expect (everything in
this range is what `v4.0.0` will point at over `v4.0.0-rc.1`):

```bash
git log --oneline v4.0.0-rc.1..main
```

You should recognise every line: the sign-off report from §14 plus
any non-functional scaffolding commits the field-test caught.
**There must be no surprises.** If you see a commit you don't
recognise, stop and investigate — a v4.0.0 tag promises bit-for-bit
correspondence with what was field-tested.

### §15.2 Cut the annotated tag

Capture the absolute path to the sign-off report so the tag
message points at it:

```bash
REPORT=$(git ls-files docs/v4/field-test-fresh-vm-*.md | grep -v template | grep -v copypaste | tail -1)
```

```bash
echo "Tagging v4.0.0 against report: $REPORT"
```

Expect the file you wrote in §14 (named
`docs/v4/field-test-fresh-vm-<host>-<ISO>.md`). If `$REPORT` is
empty, the report wasn't committed in §14 — go back and merge
that PR before continuing.

Create the annotated tag:

```bash
git tag -a v4.0.0 -m "MaluDB v4.0.0 — V4 PageIndex / ChatIndex GA after fresh-VM field-test ($REPORT)"
```

### §15.3 Push the tag

```bash
git push origin v4.0.0
```

### §15.4 Verify the tag landed

Confirm the tag is on the remote and points at the right commit:

```bash
git ls-remote origin refs/tags/v4.0.0
```

Cross-check it matches your local `main` HEAD:

```bash
git rev-parse v4.0.0 && git rev-parse main
```

The two SHAs MUST match. If they don't, the remote rejected the
push (rare — usually a permission issue) or `main` advanced
between §15.1 and §15.3 (also rare, but real). Investigate before
moving on.

Confirm the tag is the annotated kind (carries the field-test
message), not a lightweight tag:

```bash
git cat-file -t v4.0.0
```

Expect `tag`. If you see `commit`, the tag was created lightweight
(missing `-a`) — delete it locally and remotely and redo §15.2:

```bash
# only if `git cat-file -t v4.0.0` printed `commit`
git tag -d v4.0.0 && git push origin :refs/tags/v4.0.0
```

### §15.5 Post-GA follow-ups

Quick list to close out the GA event:

1. **Bump the user-manual + README** to point `Last release tag`
   at `v4.0.0` instead of `v4.0.0-rc.1`. Same edit pattern as the
   alpha → beta → rc transitions in `CHANGELOG.md`. Doc-consistency
   gate must stay green after the bump.
2. **Add a CHANGELOG entry** for `v4.0.0` summarising what
   shipped vs `v4.0.0-rc.1` (the field-test sign-off itself, plus
   any post-RC scaffolding patches that landed). Keep it short —
   the substantive work is already documented under
   `v4.0.0-alpha.1..rc.1`.
3. **Update memory** if you use auto-memory: V4 GA shipped, so the
   `v4_scope.md` description / status line moves from "Only fresh-VM
   field test remains" to "V4 GA shipped 2026-…".
4. **Close any rc.1 GA-gate issues** in the tracker if you keep
   one; reference the tag SHA.
5. **Surface the GA in the project status** — README badge,
   announcement channel, or wherever the project tracks
   release-tag visibility.

### §15.6 Anything goes wrong

If a critical bug is found within minutes of pushing `v4.0.0` and
you genuinely need to retract:

* **DO NOT** force-push a different commit onto the tag. Other
  clones already fetched the original SHA.
* Either ship a `v4.0.0.1` patch tag with the fix, or — if the
  tag has not yet been mirrored anywhere — delete it locally and
  remotely and redo `§15.2`:

  ```bash
  git tag -d v4.0.0 && git push origin :refs/tags/v4.0.0
  ```

V4 is GA when `git ls-remote origin refs/tags/v4.0.0` shows the
tag SHA matching `main` HEAD and §15.5 follow-ups are merged.

---

## §16. Troubleshooting

### `apt-get install postgresql-17` says `E: Unable to locate package`

§2 didn't run or didn't take. Re-do §2 in full and check
`apt-cache policy postgresql-17 | head -3` lists a `pgdg24.04`
candidate before retrying §3.

### `make: *** No rule to make target 'installcheck'`

You're not in the repo root. `cd` back into `maludb-core`.

### `incompatible library "...maludb_core.so": Server is version 17, library is version 18`

`make install` copied a `.so` built against the wrong PG major.
Force a clean rebuild — run these one at a time:

```bash
make clean
```

```bash
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

```bash
sudo make install PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

### `relation "malu$X" does not exist` in a pg_regress test

The extension is at an older version than 0.71.0. Confirm:

```bash
psql -d contrib_regression -c "SELECT extversion FROM pg_extension WHERE extname='maludb_core';"
```

If it shows anything other than `0.71.0`, §5 didn't fully install.
Re-run `sudo make install`.

### Python `ImportError: No module named 'psycopg'`

You need either the system package (`sudo apt-get install -y
python3-psycopg`) or the venv from §8 activated for the current
shell.

### Python `ImportError: No module named 'pypdf'`

You skipped `python3-pypdf` in §1, or you're inside the §8 venv
and didn't install `pypdf` there. Fix:

```bash
sudo apt-get install -y python3-pypdf
```

If using the venv:

```bash
pip install pypdf
```

### maludb-pageindexd unittest discovery fails with `ImportError: Start directory is not importable`

You're not in `services/maludb-pageindexd`. cd there first.

### `cmake -B build` fails with `Found libpq, version <too old>`

Force the include + lib paths:

```bash
cmake -B build -S . -DCMAKE_PREFIX_PATH=/usr/lib/postgresql/17 -DLIBPQ_INCLUDE_DIRS=/usr/include/postgresql -DLIBPQ_LIBRARIES=/usr/lib/x86_64-linux-gnu/libpq.so
```

### `scripts/maludb-fieldtest-v4: Permission denied`

```bash
chmod +x scripts/maludb-fieldtest-v4
```

### psycopg connection error `No such file or directory` on the Unix socket

The `python3-psycopg` package on Ubuntu 24.04 ships a bundled libpq
whose default socket dir is `/tmp/`, but Debian/Ubuntu PostgreSQL
listens at `/var/run/postgresql/`. The §9 `make installcheck` is
unaffected because pg_regress uses the system libpq; only §10
service/CLI smokes hit this. Fix:

```bash
export PGHOST=/var/run/postgresql
```

Do **not** fall back to `PGHOST=127.0.0.1` — PG's default
`pg_hba.conf` rejects that with `fe_sendauth: no password supplied`.

### PG fails to start: `FATAL: could not access file "pgaudit, pg_stat_statements"`

`postgresql.auto.conf` has the value written as a SQL-quoted list,
which PG round-trips as **one** double-quoted library name (comma
and all) — then refuses to load it at preload time. To see the bad
form:

```bash
sudo grep shared_preload_libraries /var/lib/postgresql/17/main/postgresql.auto.conf
```

A bad line looks like
`shared_preload_libraries = '"pgaudit, pg_stat_statements"'`
(note the inner double quotes). Recover by rewriting it as a
bare-identifier list and restarting:

```bash
sudo sed -i "s|shared_preload_libraries = '\"pgaudit, pg_stat_statements\"'|shared_preload_libraries = 'pgaudit,pg_stat_statements'|" /var/lib/postgresql/17/main/postgresql.auto.conf
```

```bash
sudo systemctl start postgresql@17-main
```

**To set this correctly from psql in the first place**, pass bare
identifiers — NOT a single quoted string containing commas:

```sql
-- correct: PG treats this as a comma-separated list of bare names
ALTER SYSTEM SET shared_preload_libraries = pgaudit, pg_stat_statements;

-- WRONG: PG stores this as one library whose name contains a comma
-- and refuses to start
ALTER SYSTEM SET shared_preload_libraries = 'pgaudit, pg_stat_statements';
```

The canonical install path (`scripts/maludb-bootstrap`) writes the
GUC via `pg_conftool` directly to `postgresql.conf` and is immune
to this trap.

### V4 bench `recall < 0.80`

The deterministic `overlap` choice strategy depends on cue tokens
appearing in the title + summary of each child the descent
considers. If the fixtures were edited and the bench drops below
0.80, the fixture's summaries no longer cover the cue path. Revert
the fixture edit, or update the cues in `bench/v4/run-bench` so
the path is reachable. Auto-generated topic summaries
(`"Auto-opened topic: X"`) do not propagate cue tokens to nested
chat leaves — keep the chat bench cues targeting root-level
children only.
