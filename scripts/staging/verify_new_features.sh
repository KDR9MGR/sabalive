#!/usr/bin/env bash
# Runs scripts/staging/verify_new_features.sql against STAGING (never production) and prints PASS / FAIL per step.
# Everything it does is rolled back. Run it after `scripts/staging/db_push.sh --apply`.
set -uo pipefail
cd "$(dirname "$0")/../.."
command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }

WORKDIR="${SUPABASE_WORKDIR:-$HOME/.sabalive-staging-workdir}"
REF=$(cat "$WORKDIR/supabase/.temp/project-ref" 2>/dev/null || echo unknown)
PROD=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
if [ "$REF" = "$PROD" ] || [ "$REF" = "unknown" ]; then echo "The staging link is missing or is the production project ($REF). Refusing."; exit 2; fi

echo "New-feature check on STAGING ($REF)  $(date -u +%Y-%m-%d\ %H:%M:%S) UTC"
OUT=$(supabase --workdir "$WORKDIR" db query --linked -o json -f "$PWD/scripts/staging/verify_new_features.sql" 2>/dev/null)
ROWS=$(echo "$OUT" | jq -c '.rows' 2>/dev/null)
if [ -z "$ROWS" ] || [ "$ROWS" = "null" ] || [ "$ROWS" = "[]" ]; then echo "  FAIL  no result from the database"; exit 1; fi
echo "$ROWS" | jq -r '.[] | [.ok, .step, (.info // "")] | @tsv' | while IFS=$'\t' read -r ok step info; do
  if [ "$ok" = "true" ]; then printf '  PASS  %s\n' "$step"; else printf '  FAIL  %s%s\n' "$step" "${info:+  <- $info}"; fi
done
FAILED=$(echo "$ROWS" | jq '[.[] | select(.ok != true)] | length')
LEFT=$(supabase --workdir "$WORKDIR" db query --linked -o json "select count(*) as n from public.live_streams where title like 'zz-smoke-test%'" 2>/dev/null | jq -r '.rows[0].n // "?"')
if [ "$LEFT" = "0" ]; then echo "  PASS  nothing left behind"; else echo "  FAIL  $LEFT leftover test row(s)"; FAILED=$((FAILED + 1)); fi
echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: ALL PASSED"; else echo "RESULT: $FAILED FAILED"; exit 1; fi
