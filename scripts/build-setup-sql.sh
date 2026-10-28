#!/usr/bin/env bash
# Concatenate all migrations into supabase/setup-new-project.sql, for pasting into a new
# Supabase project's SQL Editor. Re-run after adding a migration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/supabase/setup-new-project.sql"
{
  echo "-- RMS database setup for a NEW Supabase project (staging or production)."
  echo "-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Run it once only."
  echo "-- Generated from supabase/migrations/*.sql — do not edit by hand. Contains no test data."
  for f in "$ROOT"/supabase/migrations/*.sql; do echo; echo "-- ===== $(basename "$f") ====="; cat "$f"; done
} > "$OUT"
echo "Wrote $OUT"
