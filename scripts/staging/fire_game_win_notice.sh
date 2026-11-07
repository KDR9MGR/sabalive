#!/usr/bin/env bash
# Fires ONE real game win on STAGING (never production) so the notification strip appears on a phone that is inside a live room: the fake user1 starts a game session, bets a little
# and is paid a win of N coins through the same server functions the games use (game_apply_balance, the Tulasi path), so the notice comes from the real trigger.
#
#   scripts/staging/fire_game_win_notice.sh            # a win of 5,000 coins (the smallest that gets a strip)
#   scripts/staging/fire_game_win_notice.sh 12000      # a win of 12,000 coins
#   scripts/staging/fire_game_win_notice.sh 4999       # below the line: nothing is announced (proves the rule)
#
# Needs the staging database to have migration 20261107100000_game_win_notices and the fake accounts (docs/STAGING.md). Reads ~/sabalive-secrets/staging.env. The coins are staging play money.
set -uo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/supabase_login.sh
command -v curl >/dev/null || { echo "curl not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }
WIN="${1:-5000}"
case "$WIN" in ''|*[!0-9]*) echo "Give the win as a whole number of coins."; exit 2;; esac

ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_URL:?}" "${STAGING_PUBLISHABLE_KEY:?}" "${STAGING_TEST_PASSWORD:?}"
PROD=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE 'https://[a-z0-9]+\.supabase\.co')
[ "$STAGING_URL" != "$PROD" ] || { echo "STAGING_URL is the production address. Refusing."; exit 2; }
WORKDIR="${SUPABASE_WORKDIR:-$HOME/.sabalive-staging-workdir}"
REF=$(cat "$WORKDIR/supabase/.temp/project-ref" 2>/dev/null || echo unknown)
[ "$REF" != "unknown" ] && [ "$STAGING_URL" = "https://$REF.supabase.co" ] || { echo "The staging link folder ($REF) does not match STAGING_URL. Refusing."; exit 2; }

TOK=$(curl -s -m 20 -X POST "$STAGING_URL/auth/v1/token?grant_type=password" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H 'Content-Type: application/json' \
  -d "{\"email\":\"user1@staging.sabalive.test\",\"password\":\"$STAGING_TEST_PASSWORD\"}" | jq -r '.access_token // empty')
[ -n "$TOK" ] || { echo "Could not sign in as the fake user1."; exit 1; }
GAME_ID=$(supabase --workdir "$WORKDIR" db query --linked -o json "select id::text as id from public.merchant_games where status = 1 and not hidden order by sort_order, id limit 1" 2>/dev/null | jq -r '(if type=="array" then . else .rows end)[0].id // empty')
[ -n "$GAME_ID" ] || { echo "Staging has no enabled game (scripts/staging/seed_games.sql adds some)."; exit 1; }

S=$(curl -s -m 30 -X POST "$STAGING_URL/rest/v1/rpc/start_game_session" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d "{\"p_game_id\":\"$GAME_ID\"}")
GTOKEN=$(echo "$S" | jq -r '.token // empty'); GUID=$(echo "$S" | jq -r '.uid // empty')
[ -n "$GTOKEN" ] && [ -n "$GUID" ] || { echo "Could not start a game session: $S"; exit 1; }

BET=$(( WIN / 50 + 1 )); [ "$BET" -lt 100 ] && BET=100     # a win may be up to 100 x the stake of the last 15 minutes: bet enough
STAMP=$(date +%s)
call() { # type coin suffix
  supabase --workdir "$WORKDIR" db query --linked -o json "select public.game_apply_balance('$GTOKEN', $GUID, 'zz-fire-$STAMP-$3', $1, $2, '$GAME_ID', 'fire-test', (extract(epoch from clock_timestamp()) * 1000)::bigint, p_game_start => (extract(epoch from clock_timestamp()) * 1000)::bigint, p_game_end => (extract(epoch from clock_timestamp()) * 1000)::bigint + 60000) as r" 2>/dev/null | jq -c '(if type=="array" then . else .rows end)[0].r'
}
echo "Firing on STAGING ($REF): fake user1 bets $BET and wins $WIN coins in game $GAME_ID ..."
echo "  bet:  $(call 0 "$BET" b)"
sleep 3
echo "  win:  $(call 1 "$WIN" w)"
sleep 1
N=$(curl -s -m 20 "$STAGING_URL/rest/v1/game_win_notices?select=winner_name,game_name,coins,created_at&order=created_at.desc&limit=1" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $TOK")
echo "  latest notice: $N"
if [ "$WIN" -ge 5000 ]; then
  [ "$(echo "$N" | jq -r --argjson w "$WIN" '.[0].coins == $w')" = "true" ] && echo "RESULT: notice written - phones inside a live room are drawing the strip now" || { echo "RESULT: no notice for this win (check the lines above: the game may be switched off or the user short of coins)"; exit 1; }
else
  echo "RESULT: $WIN is below 5,000, so no strip is expected (the latest notice above is an older one, if any)"
fi
