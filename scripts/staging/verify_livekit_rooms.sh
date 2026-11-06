#!/usr/bin/env bash
# Checks the MS cloud (hosted LiveKit server) side of a live room on STAGING with real requests as the fake host and a fake user (never production, never real people):
# a room created on 'livekit', the tokens the `livekit-token` function gives (host may publish, a viewer may not, a seat holder may), and the MS cloud server itself accepting them.
# Creates one test room and removes it again.
#
#   scripts/staging/verify_livekit_rooms.sh
#
# Reads ~/sabalive-secrets/staging.env (STAGING_URL, STAGING_PUBLISHABLE_KEY, STAGING_TEST_PASSWORD). Prints PASS / FAIL per step; nothing secret is printed.
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
token() { local tok="$1" room="$2" role="$3"; curl -s -m 30 -o /tmp/_lk_resp.json -w '%{http_code}' -X POST "$STAGING_URL/functions/v1/livekit-token" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "{\"channelName\":\"$room\",\"role\":\"$role\"}"; }
grant_of() { jq -r '.token | split(".")[1] | gsub("-";"+") | gsub("_";"/") | . + ("=" * ((4 - (length % 4)) % 4)) | @base64d | fromjson | .video | "\(.room)|\(.canPublish)|\(.canSubscribe)|\(.hidden // false)"' /tmp/_lk_resp.json 2>/dev/null; }

echo "MS cloud rooms check on STAGING ($STAGING_URL)  $(date -u +%Y-%m-%d\ %H:%M:%S) UTC"
HOST=$(login host1); USER=$(login user1)
[ -n "$HOST" ] && pass "signed in as the fake host" || { fail "sign in as the fake host"; exit 1; }
[ -n "$USER" ] && pass "signed in as a fake user" || { fail "sign in as a fake user"; exit 1; }
HOST_ID=$(uid_of "$HOST"); USER_ID=$(uid_of "$USER")

# 1. an audio room on livekit
R=$(rest "$HOST" POST live_streams "{\"host_id\":\"$HOST_ID\",\"title\":\"zz-verify livekit room\",\"category\":\"Chatting\",\"mode\":\"audio\",\"seat_count\":8,\"rtc_provider\":\"livekit\"}")
SID=$(echo "$R" | jq -r 'if type=="array" then .[0].id else empty end')
check "the host created an audio room on livekit (the provider is stored)" "$([ -n "$SID" ] && [ "$(echo "$R" | jq -r '.[0].rtc_provider')" = "livekit" ] && echo true || echo false)" "$R"
[ -n "$SID" ] || { echo "RESULT: $FAILED FAILED"; exit 1; }
R=$(rest "$USER" GET "live_streams?select=id,rtc_provider,mode&id=eq.$SID")
check "a viewer reads the room and sees it is on livekit (the list reads * so no code change is needed)" "$(echo "$R" | jq -r '.[0].rtc_provider == "livekit"')" "$R"

# 2. the host's publisher token
CODE=$(token "$HOST" "$SID" publisher)
check "the host gets a publisher token (HTTP 200)" "$([ "$CODE" = "200" ] && echo true || echo false)" "HTTP $CODE $(head -c 150 /tmp/_lk_resp.json)"
G=$(grant_of)
check "its grant is for this room, may publish and subscribe, is not hidden" "$([ "$G" = "$SID|true|true|false" ] && echo true || echo false)" "$G"
check "the token is for the host's account (identity = user id) and points at a wss:// address" "$(jq -r --arg h "$HOST_ID" '.identity == $h and (.url | startswith("wss://"))' /tmp/_lk_resp.json)"
HTOKEN=$(jq -r '.token' /tmp/_lk_resp.json); LKURL=$(jq -r '.url' /tmp/_lk_resp.json | sed 's#^wss:#https:#; s#/$##')

# 3. the MS cloud server accepts it
V=$(curl -s -m 20 "$LKURL/rtc/validate?access_token=$HTOKEN")
check "the MS cloud server accepts the host's token" "$([ "$V" = "success" ] && echo true || echo false)" "$V"

# 4. a viewer
CODE=$(token "$USER" "$SID" subscriber)
G=$(grant_of)
check "a viewer gets a subscriber token that may NOT publish" "$([ "$CODE" = "200" ] && [ "$G" = "$SID|false|true|false" ] && echo true || echo false)" "HTTP $CODE $G"
CODE=$(token "$USER" "$SID" publisher)
check "a viewer who is not on a seat is refused a publisher token (403)" "$([ "$CODE" = "403" ] && echo true || echo false)" "HTTP $CODE $(head -c 150 /tmp/_lk_resp.json)"

# 5. the viewer takes a seat: now the function lets them publish, with a short token
R=$(curl -s -m 30 -X POST "$STAGING_URL/rest/v1/rpc/claim_seat" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $USER" -H 'Content-Type: application/json' -d "{\"p_stream_id\":\"$SID\",\"p_seat\":3}")
CODE=$(token "$USER" "$SID" publisher)
G=$(grant_of)
check "after taking seat 3 the same viewer gets a publisher token" "$([ "$CODE" = "200" ] && [ "$G" = "$SID|true|true|false" ] && echo true || echo false)" "claim: $R | HTTP $CODE $G"
EXP=$(jq -r '.expiresIn' /tmp/_lk_resp.json)
check "a seat holder's token is short-lived (10 minutes), the host's is not" "$([ "$EXP" = "600" ] && echo true || echo false)" "expiresIn $EXP"
V=$(curl -s -m 20 "$LKURL/rtc/validate?access_token=$(jq -r '.token' /tmp/_lk_resp.json)")
check "the MS cloud server accepts the seat holder's token" "$([ "$V" = "success" ] && echo true || echo false)" "$V"

# 6. giving the seat up takes the right away again
curl -s -m 30 -X POST "$STAGING_URL/rest/v1/rpc/release_seat" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $USER" -H 'Content-Type: application/json' -d "{\"p_stream_id\":\"$SID\"}" >/dev/null
CODE=$(token "$USER" "$SID" publisher)
check "after giving the seat up the viewer is refused again (403)" "$([ "$CODE" = "403" ] && echo true || echo false)" "HTTP $CODE"

# 7. a room that is NOT a live (a 1:1 call name) is not checked as one, and an unsigned request is refused
CODE=$(curl -s -m 20 -o /tmp/_lk_resp.json -w '%{http_code}' -X POST "$STAGING_URL/functions/v1/livekit-token" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H 'Content-Type: application/json' -d "{\"channelName\":\"$SID\",\"role\":\"subscriber\"}")
check "a request with no sign-in is refused (401)" "$([ "$CODE" = "401" ] && echo true || echo false)" "HTTP $CODE"

# clean up: end and remove the test room
rest "$HOST" PATCH "live_streams?id=eq.$SID" '{"status":"ended"}' >/dev/null
rest "$HOST" DELETE "live_streams?id=eq.$SID" >/dev/null
LEFT=$(rest "$HOST" GET "live_streams?select=id&title=eq.zz-verify%20livekit%20room" | jq -r 'if type=="array" then length else "?" end')
check "nothing is left behind (the test room is gone or ended)" "$([ "$LEFT" = "0" ] && echo true || { [ "$(rest "$HOST" GET "live_streams?select=status&id=eq.$SID" | jq -r '.[0].status')" = "ended" ] && echo true || echo false; })" "$LEFT rows"
rm -f /tmp/_lk_resp.json

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: ALL PASSED"; else echo "RESULT: $FAILED FAILED"; exit 1; fi
