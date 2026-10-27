#!/usr/bin/env bash
# Recreate a local database from scratch: Supabase shim + migrations (+ optional dev seed).
# Usage: scripts/db-reset.sh <database> [--seed]
# Uses PG* environment variables (default: postgres@localhost:54322). Never point this at production.
set -euo pipefail
DB="${1:?database name required}"
SEED="${2:-}"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-54322}" PGUSER="${PGUSER:-postgres}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
psql -q -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists \"$DB\" with (force)" -c "create database \"$DB\""
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/tests/supabase-shim.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
done
if [[ "$SEED" == "--seed" ]]; then
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/seed.sql"
fi
echo "Database $DB ready"
