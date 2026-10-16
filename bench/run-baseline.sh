#!/usr/bin/env bash
# Run the S7-1 baseline benchmark.
#
# Usage:
#   bench/run-baseline.sh [db_name] [duration_seconds] [clients]
#
# Defaults: maludb_bench, 30s, 4 clients.
#
# Creates a fresh maludb_bench database if missing, installs the
# extension, seeds, then runs pgbench for each *.sql script in
# bench/ (except seed). Captures pgbench summary output to
# bench/results/<script>.out.

set -euo pipefail

DB="${1:-maludb_bench}"
DURATION="${2:-30}"
CLIENTS="${3:-4}"
JOBS="${JOBS:-${CLIENTS}}"
PG_BIN="${PG_BIN:-/usr/lib/postgresql/17/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/results"

mkdir -p "${RESULT_DIR}"

echo "==> using PG: ${PG_BIN}"
echo "==> target db: ${DB}"
echo "==> duration: ${DURATION}s, clients: ${CLIENTS}, jobs: ${JOBS}"

# Create DB + install extension if needed.
if ! "${PG_BIN}/psql" -tAc "SELECT 1 FROM pg_database WHERE datname='${DB}'" | grep -q 1; then
    echo "==> creating database ${DB}"
    "${PG_BIN}/createdb" "${DB}"
fi
"${PG_BIN}/psql" -d "${DB}" -tAc \
    "CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE" >/dev/null

# Seed.
echo "==> seeding ${DB}"
"${PG_BIN}/psql" -d "${DB}" -f "${SCRIPT_DIR}/seed.sql" \
    > "${RESULT_DIR}/seed.out" 2>&1
tail -1 "${RESULT_DIR}/seed.out"

# Run each bench script.
for f in "${SCRIPT_DIR}"/*.sql; do
    base="$(basename "$f" .sql)"
    [[ "$base" == "seed" ]] && continue
    echo "==> pgbench ${base}"
    "${PG_BIN}/pgbench" -n -f "$f" \
        -T "${DURATION}" -c "${CLIENTS}" -j "${JOBS}" -P 5 \
        "${DB}" > "${RESULT_DIR}/${base}.out" 2>&1 || true
    awk '/^latency/ || /^tps/ {print "    " $0}' "${RESULT_DIR}/${base}.out"
done

echo "==> done. results in ${RESULT_DIR}/"
