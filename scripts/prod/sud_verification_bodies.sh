#!/usr/bin/env bash
# Prepares the test bodies for SUD's console "Verification" buttons (run it yourself, in your own terminal):
#
#   scripts/prod/sud_verification_bodies.sh              # asks for the App Id, the App Secret (HIDDEN) and your User ID (display id), then saves the bodies
#   scripts/prod/sud_verification_bodies.sh --clear      # deletes the saved bodies
#
# Why: the console will not accept a callback address until SUD's check gets a successful answer from it, and only a request carrying a token signed with your App Secret can succeed.
# What it saves: ~/sabalive-secrets/sud_verification.json (mode 600, outside git) holds four small JSON bodies. The tokens in them are login tokens for YOUR account, valid 2 hours; they are
# NOT the App Secret, and money can't move with them (coin callbacks need SUD's own signature). The App Secret is read from a hidden prompt, sent to a local node process on stdin and
# never printed, never on a command line, never stored. Then `scripts/prod/sud_copy_body.sh <name>` puts one body on the clipboard so it can be pasted into the console.
set -euo pipefail
cd "$(dirname "$0")/../.."    # sabalive/
. scripts/lib/supabase_login.sh
FILE="${SUD_VERIFICATION_FILE:-$HOME/sabalive-secrets/sud_verification.json}"
if [ "${1:-}" = "--clear" ]; then rm -f "$FILE"; echo "Deleted $FILE"; exit 0; fi
command -v node >/dev/null && command -v jq >/dev/null && command -v supabase >/dev/null || { echo "STOP: node, jq and the supabase CLI are needed"; exit 1; }
PROD_REF=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
[ "$(cat supabase/.temp/project-ref 2>/dev/null)" = "$PROD_REF" ] || { echo "STOP: this folder is not linked to production"; exit 1; }

read -r -p "App Id (the long number, not secret): " APP_ID
read -r -s -p "App Secret (hidden): " APP_SECRET; echo
read -r -p "Your User ID in the app (the number under your name, e.g. 100001): " DISPLAY_ID
[[ "$APP_ID" =~ ^[0-9]{10,25}$ ]] || { echo "STOP: the App Id is digits only"; exit 1; }
[[ "$APP_SECRET" =~ ^[A-Za-z0-9_-]{16,}$ ]] || { echo "STOP: the App Secret looks wrong (letters and digits, at least 16). Copy it again from the console."; exit 1; }
[[ "$DISPLAY_ID" =~ ^[0-9]{3,12}$ ]] || { echo "STOP: the User ID is digits only"; exit 1; }

# read-only: which profile is that (a real, non-ghost person)
ROW=$(supabase db query --linked -o json "select id, name from public.profiles where display_id = $DISPLAY_ID and not coalesce(is_ghost, false) limit 1" 2>/dev/null | jq -c 'if type=="array" then .[0] else .rows[0] end // empty')
UID_=$(printf '%s' "$ROW" | jq -r '.id // empty')
[ -n "$UID_" ] || { echo "STOP: no person with User ID $DISPLAY_ID"; exit 1; }
echo "Using $(printf '%s' "$ROW" | jq -r '.name') (User ID $DISPLAY_ID)."

mkdir -p "$(dirname "$FILE")"; umask 077
jq -n --arg a "$APP_ID" --arg s "$APP_SECRET" --arg u "$UID_" '{appId:$a, secret:$s, uid:$u}' | NODE_NO_WARNINGS=1 node scripts/prod/sud_mint_verification.mjs > "$FILE.tmp" || { rm -f "$FILE.tmp"; echo "STOP: could not make the bodies"; exit 1; }
unset APP_SECRET
mv "$FILE.tmp" "$FILE"; chmod 600 "$FILE"
echo "Saved four test bodies to $FILE (valid until $(jq -r .expires_at "$FILE"))."
echo "Next: tell Claude it is ready. When you are finished: scripts/prod/sud_verification_bodies.sh --clear"
