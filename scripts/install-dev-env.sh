#!/usr/bin/env bash
# install-dev-env.sh — Stage 1 dev-environment bring-up on Ubuntu 26.04 LTS.
#
# Installs PGDG PostgreSQL 18 + dev headers, C/Clang toolchain,
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
PG_MAJOR="${PG_MAJOR:-18}"
CLANG_MAJOR="${CLANG_MAJOR:-21}"

phase() { echo; echo "===== $* ====="; date -Iseconds; }

phase "Phase 1: PGDG apt repository"
# Accept either the legacy pgdg.list or the deb822 pgdg.sources (26.04 default).
if [[ ! -f /etc/apt/sources.list.d/pgdg.list && ! -f /etc/apt/sources.list.d/pgdg.sources ]]; then
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  PGDG_SUITE="$(. /etc/os-release && echo "${VERSION_CODENAME}")-pgdg"
  cat > /etc/apt/sources.list.d/pgdg.sources <<EOS
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: ${PGDG_SUITE}
Components: main
Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
EOS
fi
apt-get update -qq
apt-cache policy "postgresql-${PG_MAJOR}" | sed -n '1,5p'

phase "Phase 2: compiler toolchain & build deps"
apt-get install -y --no-install-recommends \
  build-essential \
  "clang-${CLANG_MAJOR}" "clang-tools-${CLANG_MAJOR}" "clang-tidy-${CLANG_MAJOR}" "llvm-${CLANG_MAJOR}-dev" \
  pkg-config bison flex \
  libicu-dev libssl-dev libreadline-dev zlib1g-dev liblz4-dev libzstd-dev libxml2-dev \
  libpq-dev libmicrohttpd-dev libjansson-dev libgnutls28-dev libcurl4-openssl-dev \
  lcov gcovr cppcheck \
  ca-certificates curl gnupg

phase "Phase 3: PostgreSQL ${PG_MAJOR} + dev headers"
apt-get install -y \
  "postgresql-${PG_MAJOR}" "postgresql-client-${PG_MAJOR}" \
  "postgresql-server-dev-${PG_MAJOR}" \
  postgresql-server-dev-all \
  postgresql-common

phase "Phase 4: extensions (pgvector, pgaudit, pg_partman)"
apt-get install -y \
  "postgresql-${PG_MAJOR}-pgvector" \
  "postgresql-${PG_MAJOR}-pgaudit" \
  "postgresql-${PG_MAJOR}-partman"

phase "Phase 5: recreate cluster ${PG_MAJOR}/main with C.UTF-8 / UTF8"
# Only recreate if the existing cluster is not already C.UTF-8 / UTF8.
need_recreate=1
if pg_lsclusters -h 2>/dev/null | awk -v v="$PG_MAJOR" '$1==v && $2=="main"' | grep -q .; then
  # lc_collate was removed as a GUC in PG 16; read the template1 collation
  # from the catalog instead (an empty result here would drop the cluster).
  current="$(sudo -u postgres psql --cluster "${PG_MAJOR}/main" -tAc \
    "SELECT datcollate || '|' || pg_encoding_to_char(encoding) || '|' FROM pg_database WHERE datname = 'template1';" \
    2>/dev/null || true)"
  echo "current cluster locale|encoding: $current"
  if [[ "$current" == *"C.UTF-8|UTF8|"* || "$current" == *"C.utf8|UTF8|"* ]]; then
    need_recreate=0
    echo "cluster already C.UTF-8 / UTF8 — skipping recreate"
  fi
fi
if [[ "$need_recreate" -eq 1 ]]; then
  if pg_lsclusters -h 2>/dev/null | awk -v v="$PG_MAJOR" '$1==v && $2=="main"' | grep -q .; then
    pg_dropcluster --stop "$PG_MAJOR" main
  fi
  pg_createcluster --locale C.UTF-8 --encoding UTF8 "$PG_MAJOR" main
  pg_ctlcluster "$PG_MAJOR" main start
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
"/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" --version
"/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" --pgxs
echo "--- psql ---"
psql --version
echo "--- clusters ---"
pg_lsclusters
echo "--- toolchain ---"
gcc --version | sed -n '1p'
"clang-${CLANG_MAJOR}" --version | sed -n '1p'
"clang-tidy-${CLANG_MAJOR}" --version | sed -n '1p'
"scan-build-${CLANG_MAJOR}" --help 2>&1 | sed -n '1p' || true
echo "--- pgvector smoke test (as $TARGET_USER) ---"
sudo -u "$TARGET_USER" psql -d "$TARGET_USER" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SELECT extname, extversion FROM pg_extension WHERE extname='vector';
SELECT '[1,2,3]'::vector <-> '[1,2,4]'::vector AS l2_distance;
DROP EXTENSION vector;
SQL
echo "--- pgaudit + pg_partman package presence ---"
dpkg -l "postgresql-${PG_MAJOR}-pgaudit" "postgresql-${PG_MAJOR}-partman" | tail -2

phase "DONE — log: $LOG"
