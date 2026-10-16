#!/usr/bin/env bash
# install-dev-env.sh — Stage 1 dev-environment bring-up on Ubuntu 24.04 LTS.
#
# Installs PGDG PostgreSQL 17 + dev headers (PG 16 + 17), C/Clang toolchain,
# pgvector / pgaudit / pg_partman, recreates the default cluster with
# C.UTF-8 / UTF8 for stable regression-test sort order, and grants the
# invoking user a PG superuser role.
#
# Run with: sudo SUDO_USER="$USER" bash scripts/install-dev-env.sh
# Idempotent: re-runs are safe; pre-existing state is detected and skipped.

set -euo pipefail

LOG="${LOG:-/var/log/maludb-install.log}"
exec > >(tee -a "$LOG") 2>&1

if [[ $EUID -ne 0 ]]; then
  echo "FATAL: must be run as root (sudo)." >&2
  exit 1
fi

# Who should become a PG superuser? Falls back to the SUDO_USER env var.
TARGET_USER="${SUDO_USER:-${TARGET_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "FATAL: TARGET_USER is empty or root. Re-run with: sudo SUDO_USER=\"\$USER\" bash $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

phase() { echo; echo "===== $* ====="; date -Iseconds; }

phase "Phase 1: PGDG apt repository"
if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
fi
apt-get update -qq
apt-cache policy postgresql-17 | sed -n '1,5p'

phase "Phase 2: compiler toolchain & build deps"
apt-get install -y --no-install-recommends \
  build-essential \
  clang-18 clang-tools-18 clang-tidy-18 llvm-18-dev \
  pkg-config bison flex \
  libicu-dev libssl-dev libreadline-dev zlib1g-dev liblz4-dev libzstd-dev libxml2-dev \
  lcov gcovr cppcheck \
  ca-certificates curl gnupg

phase "Phase 3: PostgreSQL 17 + dev headers (PG 16 + 17)"
apt-get install -y \
  postgresql-17 postgresql-client-17 \
  postgresql-server-dev-17 \
  postgresql-server-dev-16 \
  postgresql-server-dev-all \
  postgresql-common

phase "Phase 4: extensions (pgvector, pgaudit, pg_partman)"
apt-get install -y \
  postgresql-17-pgvector \
  postgresql-17-pgaudit \
  postgresql-17-partman

phase "Phase 5: recreate cluster 17/main with C.UTF-8 / UTF8"
# Only recreate if the existing cluster is not already C.UTF-8 / UTF8.
need_recreate=1
if pg_lsclusters -h 2>/dev/null | awk '$1=="17" && $2=="main"' | grep -q .; then
  current="$(sudo -u postgres psql -tAc "SHOW lc_collate; SHOW server_encoding;" 2>/dev/null | tr '\n' '|' || true)"
  echo "current cluster locale|encoding: $current"
  if [[ "$current" == *"C.UTF-8|UTF8|"* || "$current" == *"C.utf8|UTF8|"* ]]; then
    need_recreate=0
    echo "cluster already C.UTF-8 / UTF8 — skipping recreate"
  fi
fi
if [[ "$need_recreate" -eq 1 ]]; then
  if pg_lsclusters -h 2>/dev/null | awk '$1=="17" && $2=="main"' | grep -q .; then
    pg_dropcluster --stop 17 main
  fi
  pg_createcluster --locale C.UTF-8 --encoding UTF8 17 main
  pg_ctlcluster 17 main start
fi
pg_lsclusters

phase "Phase 6: superuser role + default db for $TARGET_USER"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$TARGET_USER'" \
  | grep -q 1 \
  || sudo -u postgres createuser --superuser "$TARGET_USER"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$TARGET_USER'" \
  | grep -q 1 \
  || sudo -u postgres createdb -O "$TARGET_USER" "$TARGET_USER"

phase "Phase 7: verification"
echo "--- pg_config ---"
/usr/lib/postgresql/17/bin/pg_config --version
/usr/lib/postgresql/17/bin/pg_config --pgxs
echo "--- psql ---"
psql --version
echo "--- clusters ---"
pg_lsclusters
echo "--- toolchain ---"
gcc --version | sed -n '1p'
clang-18 --version | sed -n '1p'
clang-tidy-18 --version | sed -n '1p'
scan-build-18 --help 2>&1 | sed -n '1p' || true
echo "--- PG 16 headers present? ---"
ls /usr/lib/postgresql/16/bin/pg_config 2>/dev/null && /usr/lib/postgresql/16/bin/pg_config --version || echo "PG16 pg_config not found"
echo "--- pgvector smoke test (as $TARGET_USER) ---"
sudo -u "$TARGET_USER" psql -d "$TARGET_USER" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SELECT extname, extversion FROM pg_extension WHERE extname='vector';
SELECT '[1,2,3]'::vector <-> '[1,2,4]'::vector AS l2_distance;
DROP EXTENSION vector;
SQL
echo "--- pgaudit + pg_partman package presence ---"
dpkg -l postgresql-17-pgaudit postgresql-17-partman | tail -2

phase "DONE — log: $LOG"
