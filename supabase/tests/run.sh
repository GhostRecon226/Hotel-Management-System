#!/usr/bin/env bash
# Rebuilds a scratch database from the migrations and runs every test file.
# Usage: PGHOST=/tmp PGPORT=5544 PGUSER=pgtest ./supabase/tests/run.sh
set -euo pipefail
DB=${DB:-hms_test}
export PGHOST=${PGHOST:-/tmp} PGPORT=${PGPORT:-5544} PGUSER=${PGUSER:-pgtest}
dir=$(cd "$(dirname "$0")/.." && pwd)
psql -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
psql -q -v ON_ERROR_STOP=1 -d $DB -f "$dir/tests/00_shim.sql"
for f in "$dir"/migrations/*.sql; do
  echo "== migration $(basename "$f")"
  psql -q -v ON_ERROR_STOP=1 -d $DB -f "$f"
done
for t in "$dir"/tests/[1-9]*.sql; do
  [ -e "$t" ] || continue
  echo "== test $(basename "$t")"
  psql -q -v ON_ERROR_STOP=1 -d $DB -f "$t"
done
echo "ALL OK"
