#!/usr/bin/env bash
# Replay EVERY migration, in order, on a throwaway local Postgres (nothing to install except
# Postgres itself: `brew install postgresql@15`). Run it before every `supabase db push`.
#
#   scripts/db/replay_migrations.sh                 # prints ALL_OK, or the first migration that fails
#   scripts/db/replay_migrations.sh my_test.sql     # then runs my_test.sql against the result and
#                                                   # shows its output (use it to test a new migration)
#
# It builds a brand-new cluster in a temp folder, uses port $PORT (default 54872) and deletes
# everything when it finishes. It never touches Supabase.
set -euo pipefail
cd "$(dirname "$0")/../.."    # sabalive/

PGBIN="${PGBIN:-}"
if [ -z "$PGBIN" ]; then
  for d in /opt/homebrew/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@16/bin /opt/homebrew/opt/postgresql@15/bin \
           /usr/local/opt/postgresql@15/bin /usr/lib/postgresql/*/bin; do
    if [ -x "$d/initdb" ]; then PGBIN="$d"; break; fi
  done
fi
[ -x "${PGBIN:-/nonexistent}/initdb" ] || { echo "Postgres not found. brew install postgresql@15 (or set PGBIN)"; exit 2; }

export LC_ALL=en_US.UTF-8
PORT="${PORT:-54872}"
TMP="$(mktemp -d)"
cleanup() { "$PGBIN/pg_ctl" -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

"$PGBIN/initdb" -D "$TMP/data" -U postgres --auth=trust >/dev/null
"$PGBIN/pg_ctl" -D "$TMP/data" -o "-p $PORT -k $TMP -c listen_addresses=127.0.0.1" -l "$TMP/pg.log" start -w >/dev/null
P() { "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres "$@"; }

P -q -c "create database t"
# roles etc. that already exist or NOTICEs are expected noise
P -d t -q -f scripts/db/stub.sql 2>&1 | grep -v "WARNING\|HINT\|NOTICE" || true

COUNT=0
for f in $(ls supabase/migrations/*.sql | sort); do
  if ! out=$(grep -vi "^create extension" "$f" | P -d t -q -v ON_ERROR_STOP=1 2>&1); then
    echo "FAIL $(basename "$f")"; echo "$out" | head -8; exit 1
  fi
  COUNT=$((COUNT + 1))
done
echo "ALL_OK ($COUNT migrations replayed)"

if [ "${1:-}" != "" ]; then
  echo "--- running $1"
  P -d t -f "$1"
fi
