#!/usr/bin/env bash
# Checks the shared live hearts on STAGING (never production) with real requests as the fake host and two fake users: hearts from two people add up in one total that everybody can read,
# a call adds at most 100, and an ended live takes none. Creates one test room and removes it again. Reads ~/sabalive-secrets/staging.env. Prints PASS / FAIL per step.
#
#   scripts/staging/verify_live_hearts.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
command -v curl >/dev/null || { echo "curl not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }
ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_URL:?}" "${STAGING_PUBLISHABLE_KEY:?}" "${STAGING_TEST_PASSWORD:?}"
PROD=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE 'https://[a-z0-9]+\.supabase\.co')
[ "$STAGING_URL" != "$PROD" ] || { echo "STAGING_URL is the production address. Refusing."; exit 2; }
DOMAIN="staging.sabalive.test"
FAILED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s%s\n' "$1" "${2:+  <- $2}"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "true" ]; then pass "$1"; else fail "$1" "${3:-}"; fi; }
login() { curl -s -m 20 -X POST "$STAGING_URL/auth/v1/token?grant_type=password" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H 'Content-Type: application/json' -d "{\"email\":\"$1@$DOMAIN\",\"password\":\"$STAGING_TEST_PASSWORD\"}" | jq -r '.access_token // empty'; }
uid_of() { curl -s -m 20 "$STAGING_URL/auth/v1/user" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $1" | jq -r '.id'; }
rest() { local tok="$1" method="$2" path="$3" body="${4:-}"; curl -s -m 30 -X "$method" "$STAGING_URL/rest/v1/$path" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -H 'Prefer: return=representation' ${body:+-d "$body"}; }
hearts() { curl -s -m 30 -X POST "$STAGING_URL/rest/v1/rpc/add_live_hearts" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "{\"p_stream_id\":\"$2\",\"p_count\":$3}"; }

echo "Live hearts check on STAGING ($STAGING_URL)  $(date -u +%Y-%m-%d\ %H:%M:%S) UTC"
HOST=$(login host1); U1=$(login user1); U2=$(login user2)
[ -n "$HOST" ] && [ -n "$U1" ] && [ -n "$U2" ] && pass "signed in as the fake host and two fake users" || { fail "sign in"; exit 1; }
HOST_ID=$(uid_of "$HOST")
R=$(rest "$HOST" POST live_streams "{\"host_id\":\"$HOST_ID\",\"title\":\"zz-verify hearts\",\"category\":\"Chatting\",\"mode\":\"audio\",\"seat_count\":8}")
SID=$(echo "$R" | jq -r 'if type=="array" then .[0].id else empty end')
[ -n "$SID" ] || { fail "create the test room" "$R"; exit 1; }

check "user1 sends 5 hearts: the total is 5" "$([ "$(hearts "$U1" "$SID" 5)" = "5" ] && echo true || echo false)"
check "user2 sends 7: the total is the sum, 12" "$([ "$(hearts "$U2" "$SID" 7)" = "12" ] && echo true || echo false)"
ROW=$(rest "$HOST" GET "live_hearts?select=total,last_count&live_stream_id=eq.$SID")
check "the host reads the same total and the size of the last batch" "$([ "$(echo "$ROW" | jq -r '.[0].total')" = "12" ] && [ "$(echo "$ROW" | jq -r '.[0].last_count')" = "7" ] && echo true || echo false)" "$ROW"
check "one call adds at most 100 (5000 asked: 112)" "$([ "$(hearts "$U1" "$SID" 5000)" = "112" ] && echo true || echo false)"
check "the table cannot be written directly by an app user" "$([ "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$STAGING_URL/rest/v1/live_hearts?live_stream_id=eq.$SID" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $U1" -H 'Content-Type: application/json' -d '{"total":1}')" != "200" ] && echo true || echo false)"
rest "$HOST" PATCH "live_streams?id=eq.$SID" '{"status":"ended"}' >/dev/null
check "a live that is over takes no more hearts (the total stays 112)" "$([ "$(hearts "$U2" "$SID" 10)" = "112" ] && echo true || echo false)"
rest "$HOST" DELETE "live_streams?id=eq.$SID" >/dev/null
STREAM_LEFT=$(rest "$HOST" GET "live_streams?select=status&id=eq.$SID" | jq -r 'if type=="array" then (.[0].status // "gone") else "?" end')
ROW_LEFT=$(rest "$HOST" GET "live_hearts?select=live_stream_id&live_stream_id=eq.$SID" | jq -r 'length')
# a host may be unable to delete a live (it stays, ended); then its heart row stays with it. If the live is gone, the heart row must be gone too.
check "nothing live is left behind (the room is gone, or only ended; a gone room takes its heart row with it)" "$([ "$STREAM_LEFT" = "gone" ] && [ "$ROW_LEFT" = "0" ] && echo true || { [ "$STREAM_LEFT" = "ended" ] && echo true || echo false; })" "room: $STREAM_LEFT, heart rows: $ROW_LEFT"
echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: ALL PASSED"; else echo "RESULT: $FAILED FAILED"; exit 1; fi
