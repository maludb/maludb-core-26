#!/usr/bin/env bash
# Bootstrap maludb_core 0.86.1 into a fresh DB by creating the extension at the
# sharedir version (0.82.0) then applying the repo's official delta scripts.
set -uo pipefail
PSQL="psql -v ON_ERROR_STOP=1 -X -q"
DB=mist_e2e
EXTDIR=/home/maludb/maludb-public/sql/extension
LOG=/tmp/bootstrap_086.log
: > "$LOG"

run() { echo ">>> $*" | tee -a "$LOG"; "$@" >>"$LOG" 2>&1; }

echo "== recreate database ==" | tee -a "$LOG"
psql -d postgres -v ON_ERROR_STOP=1 -X -q -c "DROP DATABASE IF EXISTS $DB;" >>"$LOG" 2>&1
psql -d postgres -v ON_ERROR_STOP=1 -X -q -c "CREATE DATABASE $DB;"        >>"$LOG" 2>&1

echo "== create extension (CASCADE pulls vector/btree_gist/pg_trgm/pgcrypto) ==" | tee -a "$LOG"
$PSQL -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;" >>"$LOG" 2>&1 || { echo "FAIL: create extension"; tail -20 "$LOG"; exit 1; }
$PSQL -d "$DB" -tAc "SELECT 'base_version='||extversion FROM pg_extension WHERE extname='maludb_core';" | tee -a "$LOG"

for step in 0.82.0--0.83.0 0.83.0--0.84.0 0.84.0--0.85.0 0.85.0--0.86.0 0.86.0--0.86.1; do
  f="$EXTDIR/maludb_core--$step.sql"
  echo "== apply delta $step ==" | tee -a "$LOG"
  # strip the psql guard line ( \echo ... \quit ) so the body runs
  if sed '/\\quit/d' "$f" | $PSQL -d "$DB" >>"$LOG" 2>&1; then
    echo "   ok: $step" | tee -a "$LOG"
  else
    echo "   FAIL at delta $step — last log lines:" | tee -a "$LOG"
    tail -25 "$LOG"
    exit 2
  fi
done

echo "== verify 0.86.1 surface present ==" | tee -a "$LOG"
$PSQL -d "$DB" -tAc "
SELECT string_agg(p.proname,', ' ORDER BY p.proname)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='maludb_core'
  AND p.proname IN ('uedge_walk','uedge_neighbors','attributes_jsonb','object_get','attributes_apply','register_object_embedding','semantic_search','register_svpor_statement');" | tee -a "$LOG"
echo "DONE"
