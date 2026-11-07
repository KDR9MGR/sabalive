#!/usr/bin/env bash
# Fires ONE real big gift on STAGING (never production) so the notification strip appears on a phone: the fake host1 opens a throw-away live room, the fake user1 sends the most
# expensive gift to host1 through the real send_gift_v2 (as many as it takes to reach N coins), the trigger on the gift's chat row writes the notice, then the room is removed.
#
#   scripts/staging/fire_gift_notice.sh            # a gift send worth at least 5,000 coins (the smallest that gets a strip)
#   scripts/staging/fire_gift_notice.sh 20000      # worth at least 20,000 coins
#   scripts/staging/fire_gift_notice.sh 4000       # below the line: nothing is announced (proves the rule)
#
# Needs staging to have migration 20261107110000_gift_notices and the fake accounts (docs/STAGING.md). Reads ~/sabalive-secrets/staging.env. The coins are staging play money.
set -uo pipefail
cd "$(dirname "$0")/../.."
command -v curl >/dev/null || { echo "curl not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }
WANT="${1:-5000}"
case "$WANT" in ''|*[!0-9]*) echo "Give the worth as a whole number of coins."; exit 2;; esac

ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_URL:?}" "${STAGING_PUBLISHABLE_KEY:?}" "${STAGING_TEST_PASSWORD:?}"
PROD=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE 'https://[a-z0-9]+\.supabase\.co')
[ "$STAGING_URL" != "$PROD" ] || { echo "STAGING_URL is the production address. Refusing."; exit 2; }
DOMAIN="staging.sabalive.test"
login() { curl -s -m 20 -X POST "$STAGING_URL/auth/v1/token?grant_type=password" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H 'Content-Type: application/json' -d "{\"email\":\"$1@$DOMAIN\",\"password\":\"$STAGING_TEST_PASSWORD\"}" | jq -r '.access_token // empty'; }
uid_of() { curl -s -m 20 "$STAGING_URL/auth/v1/user" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $1" | jq -r '.id'; }
rest() { local tok="$1" method="$2" path="$3" body="${4:-}"; curl -s -m 30 -X "$method" "$STAGING_URL/rest/v1/$path" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -H 'Prefer: return=representation' ${body:+-d "$body"}; }

HOST=$(login host1); USER=$(login user1)
[ -n "$HOST" ] && [ -n "$USER" ] || { echo "Could not sign in as the fake host1 / user1."; exit 1; }
HOST_ID=$(uid_of "$HOST")

if [ "$WANT" -lt 5000 ]; then   # below the line: the dearest gift that costs no more than WANT, once
  GIFT=$(rest "$USER" GET "gifts?select=id,name,price_coins&price_coins=lte.$WANT&order=price_coins.desc&limit=1")
else                              # at or above the line: the dearest gift, as many as it takes
  GIFT=$(rest "$USER" GET "gifts?select=id,name,price_coins&order=price_coins.desc&limit=1")
fi
GID=$(echo "$GIFT" | jq -r '.[0].id // empty'); PRICE=$(echo "$GIFT" | jq -r '.[0].price_coins // empty'); GNAME=$(echo "$GIFT" | jq -r '.[0].name // empty')
[ -n "$GID" ] && [ -n "$PRICE" ] || { echo "Staging has no gift cheap enough for $WANT coins."; exit 1; }
if [ "$WANT" -lt 5000 ]; then QTY=$(( WANT / PRICE )); else QTY=$(( (WANT + PRICE - 1) / PRICE )); fi
[ "$QTY" -lt 1 ] && QTY=1; [ "$QTY" -gt 99 ] && QTY=99
COST=$(( PRICE * QTY ))

R=$(rest "$HOST" POST live_streams "{\"host_id\":\"$HOST_ID\",\"title\":\"zz-fire gift notice\",\"category\":\"Chatting\",\"mode\":\"audio\",\"seat_count\":8}")
SID=$(echo "$R" | jq -r 'if type=="array" then .[0].id else empty end')
[ -n "$SID" ] || { echo "Could not open a throw-away room: $R"; exit 1; }
echo "Firing on STAGING: fake user1 sends $QTY x $GNAME ($PRICE coins each = $COST) to host1 in a throw-away room ..."
S=$(curl -s -m 30 -X POST "$STAGING_URL/rest/v1/rpc/send_gift_v2" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $USER" -H 'Content-Type: application/json' \
  -d "{\"p_gift_id\":\"$GID\",\"p_receiver_id\":\"$HOST_ID\",\"p_live_stream_id\":\"$SID\",\"p_quantity\":$QTY}")
echo "  send: $S"
sleep 1
N=$(curl -s -m 20 "$STAGING_URL/rest/v1/gift_notices?select=sender_name,receiver_name,gift_name,quantity,coins,created_at&order=created_at.desc&limit=1" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $USER")
echo "  latest notice: $N"
rest "$HOST" PATCH "live_streams?id=eq.$SID" '{"status":"ended"}' >/dev/null
rest "$HOST" DELETE "live_streams?id=eq.$SID" >/dev/null
if [ "$COST" -ge 5000 ]; then
  [ "$(echo "$N" | jq -r --argjson c "$COST" '.[0].coins == $c')" = "true" ] && echo "RESULT: notice written - phones on Home or in a live room are drawing the strip now" || { echo "RESULT: no notice for this gift (see the lines above: the send may have been refused)"; exit 1; }
else
  echo "RESULT: $COST is below 5,000, so no strip is expected (the latest notice above is an older one, if any)"
fi
