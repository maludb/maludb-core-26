# V3 Fresh-VM Field Test — Copy-Paste Commands

Every command in this file is on a **single line**. Copy a line,
paste it into your VM shell, run it. No line continuations.

The narrative explanation of *why* each step exists lives in
`field-test-fresh-vm.md`. This file is just commands.

---

## §1. OS prerequisites

```bash
sudo apt-get update
```

```bash
sudo apt-get install -y build-essential pkg-config bison flex libicu-dev libssl-dev libreadline-dev zlib1g-dev liblz4-dev libzstd-dev libxml2-dev libmicrohttpd-dev libjansson-dev libgnutls28-dev libcurl4-openssl-dev jq curl git python3 python3-psycopg python3-pytest cmake clang-19 lcov
```

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
`17.9-1.pgdg24.04+1`). If `Candidate:` is `(none)`, §2 didn't take
— re-run the §2 commands.

---

## §3. Install PostgreSQL 17 + V3-required extensions

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

## §4. Clone the repo at the V3 RC tag

```bash
git clone https://github.com/maludb/maludb-core.git
```

```bash
cd maludb-core
```

```bash
git checkout v3.0.0-rc.1
```

```bash
git log -1 --oneline
```

Expect the HEAD to be detached at `v3.0.0-rc.1`.

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

Expect `default_version = '0.57.0'`.

```bash
ls /usr/share/postgresql/17/extension/maludb_core--*.sql | wc -l
```

Expect 57.

---

## §6. Python environment (only if `python3-psycopg` is unavailable)

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
pip install "psycopg[binary]>=3.1" pytest
```

If you use the venv, every Python suite below must be run from a
shell where the venv is still activated.

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

## §8. Run pg_regress (primary V3 gate)

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

**Expect the last line:** `# All 66 tests passed.`

If any test fails, the per-test diff lives in
`results/<name>.out.diff`.

---

## §9. Run the V3 service / CLI / SDK smokes

Run these immediately after §8 so `contrib_regression` is still
populated.

### §9.1 maludb-restd

```bash
cd services/maludb-restd
```

```bash
MALUDB_RESTD_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect `7 passed`.

### §9.2 maludb-realtimed

```bash
cd ../maludb-realtimed
```

```bash
MALUDB_REALTIMED_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect `4 passed`.

### §9.3 maludb CLI

```bash
cd ../../cli/maludb
```

```bash
MALUDB_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect `11 passed`.

### §9.4 libmaludb (C SDK)

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

Expect both `smoke` and `smoke_v02` to pass (6 + 12 named PASS
lines).

---

## §10. Run the V3 end-to-end orchestration

```bash
cd ../..
```

```bash
MALUDB_FT_DB=contrib_regression scripts/maludb-fieldtest-v3
```

**Expect the last line:** `Result: 30 pass / 0 fail / 0 warn`.

### §10 capture for the sign-off

```bash
MALUDB_FT_DB=contrib_regression scripts/maludb-fieldtest-v3 --json > /tmp/v3-fieldtest-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).json
```

```bash
ls -la /tmp/v3-fieldtest-*.json
```

---

## §11. Run the doc-consistency gate

```bash
scripts/maludb-check-doc-consistency
```

Expect:

```
maludb-check-doc-consistency: OK
  default_version = 0.57.0 (control, README, user-manual all agree)
  release tag     = v3.0.0-rc.1 (README, CHANGELOG, user-manual all agree)
  PG majors       = 16,17,18 (manual) / 16,17,18 (CI)
  services        = maludb_modeld, maludb_mc2dbd, mcp-broker
  SDKs            = C, Python, Node.js, PHP
```

---

## §12. Sign-off

```bash
HOST=$(hostname)
```

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
```

```bash
REPORT="docs/v3/field-test-fresh-vm-${HOST}-${TS}.md"
```

```bash
cp docs/v3/field-test-report-2026-05-14.md "$REPORT"
```

```bash
echo "$REPORT"
```

Then edit `$REPORT`:

1. Replace the **Host** table at the top with this VM's hostname,
   OS version (`lsb_release -a`), PG version (from §3 verify),
   tag (`v3.0.0-rc.1`), and today's UTC date.
2. Paste the **last line of each suite's output** into the
   corresponding row of the Suites table.
3. Flip **V3 acceptance criterion #2** from `PARTIAL` to `PASS`,
   citing this VM's hostname.
4. Append the JSON snippet captured in §10 as a fenced block at
   the bottom.

```bash
git checkout -b ga-gate-${HOST}-${TS}
```

```bash
git add "$REPORT"
```

```bash
git commit -m "V3 GA gate: fresh-VM field-test on ${HOST} (${TS})"
```

```bash
git push -u origin "ga-gate-${HOST}-${TS}"
```

Open a pull request titled
`V3 GA gate: fresh-VM field-test on ${HOST}`, attach the JSON
artefact, merge after review, then tag GA:

```bash
git checkout main
```

```bash
git pull
```

```bash
git tag -a v3.0.0 -m "MaluDB v3.0.0 — V3 GA after fresh-VM field-test"
```

```bash
git push origin v3.0.0
```

---

## Troubleshooting

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

The extension is at an older version than 0.57.0. Confirm:

```bash
psql -d contrib_regression -c "SELECT extversion FROM pg_extension WHERE extname='maludb_core';"
```

If it shows anything other than `0.57.0`, §5 didn't fully install.
Re-run `sudo make install`.

### Python `ImportError: No module named 'psycopg'`

You need either the system package (`sudo apt-get install -y
python3-psycopg`) or the venv from §6 activated for the current
shell.

### `cmake -B build` fails with `Found libpq, version <too old>`

Force the include + lib paths:

```bash
cmake -B build -S . -DCMAKE_PREFIX_PATH=/usr/lib/postgresql/17 -DLIBPQ_INCLUDE_DIRS=/usr/include/postgresql -DLIBPQ_LIBRARIES=/usr/lib/x86_64-linux-gnu/libpq.so
```

### `scripts/maludb-fieldtest-v3: Permission denied`

```bash
chmod +x scripts/maludb-fieldtest-v3
```

### psycopg connection error `No such file or directory` on the Unix socket

The `python3-psycopg` package on Ubuntu 24.04 ships a bundled libpq
whose default socket dir is `/tmp/`, but Debian/Ubuntu PostgreSQL
listens at `/var/run/postgresql/`. The §8 `make installcheck` is
unaffected because pg_regress uses the system libpq; only §9
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

The canonical install path is `scripts/maludb-bootstrap`, which
writes the GUC via `pg_conftool` directly to `postgresql.conf` and
is immune to this trap entirely.
