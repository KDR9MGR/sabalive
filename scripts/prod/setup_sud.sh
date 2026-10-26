#!/usr/bin/env bash
# One-time SUD setup on PRODUCTION: sets the three SUD secrets and deploys the `sud` Edge Function. RUN IT YOURSELF, in your own terminal:
#
#   scripts/prod/setup_sud.sh            # asks for the App ID, App Key and App Secret (the key and secret are typed or pasted into HIDDEN prompts), then deploys
#   scripts/prod/setup_sud.sh --check    # only checks that it could run (account, project, function folder, which SUD secrets exist) and asks for nothing
#   scripts/prod/setup_sud.sh --deploy-only   # the three secrets are ALREADY in Supabase (added in the dashboard, any capitals: SUD_App_Key works): just deploy the function and check it
#
# Where the values are: SUD console (console.sud.tech) > Service Management > Application Management > your application > Edit: App Id, App Key, App Secret
# (the eye icon shows a value, the copy icon copies it). The key and the secret are NEVER printed, never put on a command line (so `ps` cannot show them), never written to
# a file other than a temporary 600-mode one that is deleted when the script ends, and never go anywhere except Supabase's secret store for this project. Do not paste them into chat.
#
# It refuses to run unless the link folder is really production, asks you to type `production` before it changes anything, and afterwards checks that the function answers.
# It sets SUD_TEST_ENV=1: the SUD web SDK talks to SUD's TEST environment until SUD has put the application live (then set SUD_TEST_ENV=0 the same way).
# What this does NOT do: the SUD console settings (Web bundle_id sabalive.in and the callback URLs), the panel's games, or the switches: see docs/SUD_GAMES.md.
set -euo pipefail
cd "$(dirname "$0")/../.."    # sabalive/
. scripts/lib/supabase_login.sh   # the sabalive account token from ~/sabalive-secrets/supabase.env, so a wrong stored login cannot redirect this

say() { printf '%s\n' "$*"; }
die() { printf 'STOP: %s\n' "$*"; exit 1; }
command -v supabase >/dev/null || die "supabase CLI not found"
command -v curl >/dev/null || die "curl not found"

CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
DEPLOY_ONLY=0; [ "${1:-}" = "--deploy-only" ] && DEPLOY_ONLY=1
[ -z "${SUPABASE_WORKDIR:-}" ] || die "SUPABASE_WORKDIR is set (another project's link folder): unset it, this script is for production only"
PROD_REF=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
LINKED=$(cat supabase/.temp/project-ref 2>/dev/null || echo "")
[ -n "$PROD_REF" ] && [ "$LINKED" = "$PROD_REF" ] || die "this folder is linked to '${LINKED:-nothing}', not production ($PROD_REF)"
[ -f supabase/functions/sud/index.ts ] || die "supabase/functions/sud/index.ts is missing"
BASE="https://$PROD_REF.supabase.co/functions/v1/sud"

say "Project: $PROD_REF (production)"
say "Account: $(supabase projects list 2>/dev/null | grep -E '^\s*●' | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}' | head -1)"
say "The function's address, for the SUD console's callbacks:"
say "  get_sstoken_url        $BASE/get_sstoken"
say "  update_sstoken_url     $BASE/update_sstoken"
say "  report_game_info_url   $BASE/report_game_info"
say "  notify_url             $BASE/notify"
# which of the three secrets are there (names only; the function matches a name ignoring capitals, so SUD_App_Key counts as SUD_APP_KEY)
NAMES=$(supabase secrets list 2>/dev/null | awk -F'|' 'NR>2 {gsub(/^ +| +$/,"",$1); print toupper($1)}')
have() { printf '%s\n' "$NAMES" | grep -qx "$1"; }
MISSING=""; for n in SUD_APP_ID SUD_APP_KEY SUD_APP_SECRET; do have "$n" || MISSING="$MISSING $n"; done
say "SUD secrets on this project (ignoring capitals): $(for n in SUD_APP_ID SUD_APP_KEY SUD_APP_SECRET; do have "$n" && printf '%s ok  ' "$n" || printf '%s MISSING  ' "$n"; done)"
if [ "$CHECK" -eq 1 ]; then
  [ -z "$MISSING" ] && say "All three are there: run  $0 --deploy-only  to deploy the function." || say "Missing:$MISSING (add them in the Supabase dashboard > Edge Functions > Secrets, or run this script without options)."
  say "CHECK OK: nothing was changed."; exit 0
fi

if [ "$DEPLOY_ONLY" -eq 1 ]; then
  [ -z "$MISSING" ] || die "missing:$MISSING. Add them in the Supabase dashboard (Edge Functions > Secrets), or run this script without options to be asked for them."
  read -r -p "Type  production  to deploy the sud function on $PROD_REF with the secrets that are already there: " GO
  [ "$GO" = "production" ] || die "not confirmed, nothing was changed"
else
say
read -r -p "App Id (the long number, not secret): " APP_ID
read -r -s -p "App Key (hidden): " APP_KEY; echo
read -r -s -p "App Secret (hidden): " APP_SECRET; echo
for v in APP_ID APP_KEY APP_SECRET; do
  val="${!v}"
  [[ "$val" =~ ^[A-Za-z0-9_-]{16,}$ ]] || die "$v looks wrong (letters and digits only, at least 16 of them, no spaces). Copy it again from the console."
done
[[ "$APP_ID" =~ ^[0-9]{10,25}$ ]] || die "App Id is digits only"
[ "$APP_KEY" != "$APP_SECRET" ] || die "the App Key and the App Secret are the same: one of them was copied twice"
say "Got them (key $((${#APP_KEY})) characters, secret $((${#APP_SECRET})) characters; not shown)."

read -r -p "Type  production  to set the secrets and deploy the sud function on $PROD_REF: " GO
[ "$GO" = "production" ] || die "not confirmed, nothing was changed"

TMP=$(mktemp); chmod 600 "$TMP"; trap 'rm -f "$TMP"' EXIT
{ printf 'SUD_APP_ID=%s\n' "$APP_ID"; printf 'SUD_APP_KEY=%s\n' "$APP_KEY"; printf 'SUD_APP_SECRET=%s\n' "$APP_SECRET"; printf 'SUD_TEST_ENV=1\n'; } > "$TMP"
unset APP_KEY APP_SECRET
supabase secrets set --env-file "$TMP" >/dev/null 2>&1 || die "setting the secrets failed (run  supabase secrets list  to see what is there)"
rm -f "$TMP"
say "Secrets set (names: SUD_APP_ID, SUD_APP_KEY, SUD_APP_SECRET, SUD_TEST_ENV)."

fi

supabase functions deploy sud --no-verify-jwt --use-api 2>&1 | grep -E "Deployed|rror" | head -3 || true

# an unsigned, empty call: a configured function answers HTTP 200 with ret_code 1 ("code ... "), an unconfigured one answers 500 and names the empty secret
sleep 4
OUT=$(curl -s -m 20 -o /tmp/sud_check.$$ -w '%{http_code}' -X POST "$BASE/get_sstoken" -H 'Content-Type: application/json' -d '{}' || echo 000)
BODY=$(cat /tmp/sud_check.$$ 2>/dev/null || true); rm -f /tmp/sud_check.$$
if [ "$OUT" = "200" ] && printf '%s' "$BODY" | grep -q '"ret_code"'; then
  say "CHECK OK: the sud function is live and configured (HTTP 200, answers in SUD's format)."
  say "Next: SUD console > your application > Edit: set the Web bundle_id to  sabalive.in  and the four callback URLs above, then Submit."
else
  say "CHECK FAILED: HTTP $OUT. The function may still be starting: run  $0 --check  in a minute, or look at the function's logs in the Supabase dashboard."
  exit 1
fi
