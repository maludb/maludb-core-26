# MaluDB V3 Fresh-VM Field-Test Procedure

This document is the GA blocker for `v3.0.0`. Run it on a
**freshly-provisioned Ubuntu 24.04 LTS host** with no prior MaluDB
state. The same-host run on 2026-05-14 (see
`field-test-report-2026-05-14.md`) already exercised every shipped
V3 surface; this procedure proves the same against an installer
that has never seen MaluDB before.

Estimated time: **30–45 minutes** including PG download.

## 0. Provision the host

Any provisioner is fine. Minimum spec:

- Ubuntu **24.04 LTS** server (Noble Numbat), x86_64.
- ≥ 2 vCPU, ≥ 4 GiB RAM, ≥ 20 GiB disk.
- Outbound network to `apt.postgresql.org`, `pypi.org`, and your
  git remote.
- `sudo` access for the operator user.
- No PostgreSQL preinstalled. If the cloud image ships with
  PG, purge it: `sudo systemctl stop postgresql && sudo apt-get
  purge -y 'postgresql-*' 'postgresql-client-*' && sudo apt-get
  autoremove -y`.

Example (AWS):

```
aws ec2 run-instances \
  --image-id <ubuntu-24.04-amd64-ami> \
  --instance-type t3.medium \
  --key-name <your-key> \
  --security-group-ids <sg-with-22-and-443-out>
```

## 1. Install OS prerequisites

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential pkg-config bison flex \
    libicu-dev libssl-dev libreadline-dev zlib1g-dev liblz4-dev libzstd-dev \
    libxml2-dev libmicrohttpd-dev libjansson-dev libgnutls28-dev libcurl4-openssl-dev \
    jq curl git python3 python3-psycopg python3-pytest \
    cmake clang-19 lcov
```

> `python3-psycopg` is the system-packaged psycopg 3. If your image
> doesn't have it, install via pip3 into a venv: see §6.

## 2. Add the PGDG apt repository

```bash
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update
```

## 3. Install PostgreSQL 17 + required extensions

```bash
sudo apt-get install -y \
    postgresql-17 \
    postgresql-server-dev-17 \
    postgresql-17-pgvector \
    postgresql-17-pgaudit \
    postgresql-17-partman
```

The base postgresql-17 package includes pgcrypto, btree_gist, and
pg_trgm — no extra apt action needed.

Confirm:

```bash
/usr/lib/postgresql/17/bin/pg_config --version
sudo systemctl is-active postgresql
psql -V
```

Expect PostgreSQL 17.9 (or later 17.x on PGDG noble) and the
service active.

## 4. Clone the repo at the V3 RC tag

```bash
git clone https://github.com/maludb/maludb-core.git
cd maludb-core
git checkout v3.0.0-rc.1
```

> If you have a mirror of this repo elsewhere, substitute the URL
> but pin to `v3.0.0-rc.1`. The procedure below assumes you are in
> the repo
> root.

## 5. Build + install the extension

```bash
export PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
make clean
make PG_CONFIG="$PG_CONFIG"
sudo make install PG_CONFIG="$PG_CONFIG"
```

Verify the SQL files landed:

```bash
ls /usr/share/postgresql/17/extension/maludb_core--0.57.0.sql 2>/dev/null \
    || ls /usr/share/postgresql/17/extension/maludb_core--*.sql | tail -3
grep default_version /usr/share/postgresql/17/extension/maludb_core.control
```

Expect `default_version = '0.57.0'`.

## 6. Python environment for service / CLI smokes

If `python3-psycopg` is on the system path, skip the venv. Otherwise:

```bash
sudo apt-get install -y python3-venv
python3 -m venv /tmp/maludb-ft-venv
source /tmp/maludb-ft-venv/bin/activate
pip install "psycopg[binary]>=3.1" pytest
```

You'll need this venv (or system psycopg) for every Python suite in
steps §9 and §10.

## 7. Initialize the test database

The pg_regress harness will manage its own `contrib_regression`
database; you do NOT need to create the runtime `maludb` database
for the field test.

If your install rule needs `peer` auth (default on PGDG Ubuntu),
the `postgres` superuser can run installcheck via `sudo`:

```bash
sudo -u postgres /usr/lib/postgresql/17/bin/createdb -O "$USER" contrib_regression || true
```

For a tighter run, allow your shell user to be a PostgreSQL
superuser:

```bash
sudo -u postgres psql -c "CREATE USER $USER SUPERUSER;"
sudo -u postgres psql -c "ALTER USER $USER WITH PASSWORD NULL;"
```

(For production this would be the operator account; the field test
runs every test as a superuser by design.)

## 8. Run pg_regress (the primary V3 gate)

```bash
make installcheck PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

**Expect: `# All 66 tests passed.`** on PG 17.

If any test fails, the diff is in
`results/<test>.out.diff`. The 66/66 floor includes 51 Stage 1-7
tests + 15 V3 tests (auth_token, secret_store, rest_endpoint,
queue, cron_schedule, source_archive, realtime_event,
pool_presence, vector_filter, embed_pipeline, retrieval_envelope,
metrics_scrape, log_drain, backup_manifest, preview_env).

## 9. Run the V3 service / CLI / SDK smokes

These all assume `contrib_regression` is populated by the prior
`make installcheck` run. **Run them immediately after step §8** so
the extension state is fresh.

### 9.1 maludb-restd

```bash
cd services/maludb-restd
MALUDB_RESTD_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect 7 passed.

### 9.2 maludb-realtimed

```bash
cd ../maludb-realtimed
MALUDB_REALTIMED_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect 4 passed.

### 9.3 maludb CLI

```bash
cd ../../cli/maludb
MALUDB_DB=contrib_regression PYTHONPATH=src python3 -m pytest tests/ -v
```

Expect 11 passed.

### 9.4 libmaludb (C SDK)

```bash
cd ../../drivers/c
cmake -B build -S .
cmake --build build
MALUDB_TEST_DSN="dbname=contrib_regression" ctest --test-dir build --output-on-failure
```

Expect:
- `maludb_smoke` (v0.1) 6 named PASS lines, exit 0.
- `maludb_smoke_v02` (v0.2) 12 named PASS lines, exit 0.

## 10. Run the V3 end-to-end orchestration

```bash
cd ../..
MALUDB_FT_DB=contrib_regression scripts/maludb-fieldtest-v3
```

**Expect: `Result: 30 pass / 0 fail / 0 warn`** across the eight V3
stages.

Capture the output:

```bash
MALUDB_FT_DB=contrib_regression scripts/maludb-fieldtest-v3 --json \
    > /tmp/v3-fieldtest-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).json
```

## 11. Run the doc-consistency gate

```bash
scripts/maludb-check-doc-consistency
```

Expect:

```
maludb-check-doc-consistency: OK
  default_version = 0.57.0 ...
  release tag     = v3.0.0-rc.1 ...
```

## 12. Sign-off

Capture all five suite results into a per-host report. From the repo
root:

```bash
HOST=$(hostname)
TS=$(date -u +%Y%m%dT%H%M%SZ)
REPORT=docs/v3/field-test-fresh-vm-${HOST}-${TS}.md
cp docs/v3/field-test-report-2026-05-14.md "$REPORT"
# Edit "$REPORT" — replace the Host / Tag / Date table with this
# host's values, paste each suite's terminal output into the
# corresponding section, and flip §V3 acceptance §2 from PARTIAL
# to PASS.
```

Commit the report on a topic branch and open a PR titled
`V3 GA gate: fresh-VM field-test on <hostname>`. Tag `v3.0.0` only
after that PR merges.

## What to do if a step fails

- **Step §3 (apt install of postgresql-17-pgvector):** make sure
  `pgdg.list` actually has `noble-pgdg main` (some downloads end
  up with the older `bookworm-pgdg`). `cat /etc/apt/sources.list.d/pgdg.list`
  must mention `noble`.
- **Step §5 (`make install` permission denied):** the install
  rule writes into `/usr/lib/postgresql/17/lib/`; you need
  `sudo make install`, not `make install`.
- **Step §8 (`load` test fails with "version mismatch"):**
  somebody rebuilt the `.so` against a different PG major. From a
  fresh checkout this should not happen; if it does, `make clean
  && make && sudo make install` against the right `PG_CONFIG`.
- **Step §8 (a V3 test fails with `relation "malu$X" does not
  exist`):** the extension didn't reach 0.57.0. `psql -d
  contrib_regression -c "SELECT extversion FROM pg_extension WHERE
  extname='maludb_core'"` should show `0.57.0`. If it shows an
  earlier version, the `.control`'s `default_version` is stale —
  re-run `sudo make install`.
- **Step §9 (psycopg ImportError):** activate the venv from §6.
- **Step §10 (`scripts/maludb-fieldtest-v3` not executable):**
  `chmod +x scripts/maludb-fieldtest-v3`.

## Expected runtime

| Step | Wall time |
|---|---|
| §1-3 OS + PG install | 5–10 min |
| §4 git clone           | 30 s |
| §5 make + install      | 1–2 min |
| §6 python venv         | 30 s |
| §8 pg_regress 66/66    | 1–2 min |
| §9 service + CLI smokes | 30 s each |
| §9.4 libmaludb cmake+ctest | 2 min |
| §10 fieldtest-v3       | 5 s |
| §11 doc gate           | < 1 s |
| §12 capture + commit   | 5 min |
| **total**              | **~30–45 min** |

## What this proves

- The V3 catalog migrations (`0.41.0 → 0.57.0`) apply cleanly from
  scratch on a never-seen-MaluDB-before host.
- Every shipped V3 service binary starts and responds to its
  smokes against the live PG.
- The CLI's 14 subcommand families (no `StagePendingError` stubs)
  all reach real SQL.
- The V3 acceptance criterion #2 ("fresh Ubuntu 24.04 host ...
  passes field test") is satisfied.

After a green fresh-VM run, `v3.0.0` is ready to tag and ship.
