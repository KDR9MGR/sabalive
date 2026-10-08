#!/usr/bin/env bash
# Replays the live Play app's key actions against the LINKED project and rolls them back.
# Run it right after a database push (and before one, to know the starting point).
#
#   scripts/prod/smoke_play_app.sh
#
# Safe on production (see the header of smoke_play_app.sql): everything happens in one transaction
# that is rolled back. Quietest hour is best; it takes brief locks.
# Exit code 0 = every step passed, 1 = something the Play app needs is broken.
set -uo pipefail
cd "$(dirname "$0")/../.."

command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }
sb() { supabase ${SUPABASE_WORKDIR:+--workdir "$SUPABASE_WORKDIR"} "$@"; }   # SUPABASE_WORKDIR targets another project

echo "Play-app smoke test  ($(date -u +%Y-%m-%d\ %H:%M:%S) UTC)  project: $(cat "${SUPABASE_WORKDIR:-.}/supabase/.temp/project-ref" 2>/dev/null || echo unknown)"
OUT=$(sb db query --linked -o json -f "$PWD/scripts/prod/smoke_play_app.sql" 2>/dev/null)
ROWS=$(echo "$OUT" | jq -c '.rows' 2>/dev/null)
if [ -z "$ROWS" ] || [ "$ROWS" = "null" ] || [ "$ROWS" = "[]" ]; then
  echo "  FAIL  no result from the database (is it up? run scripts/prod/healthcheck.sh)"
  exit 1
fi

FAILED=0
echo "$ROWS" | jq -r '.[] | [.ok, .step, (.info // "")] | @tsv' | while IFS=$'\t' read -r ok step info; do
  if [ "$ok" = "true" ]; then printf '  PASS  %s%s\n' "$step" "${info:+  ($info)}"
  else printf '  FAIL  %s%s\n' "$step" "${info:+  <- $info}"; fi
done
FAILED=$(echo "$ROWS" | jq '[.[] | select(.ok != true)] | length')

# prove the rollback left nothing behind
LEFT=$(sb db query --linked -o json "select count(*) as n from public.live_streams where title like 'zz-smoke-test%'" 2>/dev/null | jq -r '.rows[0].n // "?"')
if [ "$LEFT" = "0" ]; then echo "  PASS  nothing left behind in production"
else echo "  FAIL  $LEFT leftover test row(s) in live_streams (title starts with zz-smoke-test): delete them"; FAILED=$((FAILED + 1)); fi

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: ALL PASSED"; exit 0
else echo "RESULT: $FAILED FAILED. Do not leave this in production without a plan (see docs/DEPLOY_CHECKLIST.md > If something breaks)."; exit 1; fi
