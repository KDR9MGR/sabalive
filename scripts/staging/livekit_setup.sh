#!/usr/bin/env bash
# STAGING ONLY. Puts the new `livekit-token` Edge Function on the staging project and gives it the LiveKit (LiveCore) address, key and secret.
#
#   scripts/staging/livekit_setup.sh --deploy     deploy the function (no secrets needed)
#   scripts/staging/livekit_setup.sh --secrets    set LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET on staging, read from ~/sabalive-secrets/livekit-staging.env
#   scripts/staging/livekit_setup.sh --check      ask the deployed function what it needs (expects "must be signed in" when it is alive, never a secret)
#
# The values live ONLY in that file (outside git, chmod 600; make it yourself with three NAME=value lines) and are never printed. Production's project is
# refused. `agora-token` is not touched: this is a second function next to it (docs/STREAMING_SERVER_SWAP.md).
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/supabase_login.sh

ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
LK_FILE="${LIVEKIT_ENV_FILE:-$HOME/sabalive-secrets/livekit-staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_REF:?}" "${STAGING_URL:?}"

PROD_REF=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
if [ "$STAGING_REF" = "$PROD_REF" ] || [ "$STAGING_REF" = "$(cat supabase/.temp/project-ref 2>/dev/null)" ]; then
  echo "STAGING_REF is the production project. Refusing."; exit 2
fi
WORK="${STAGING_WORKDIR:-$HOME/.sabalive-staging-workdir}"
[ "$(cat "$WORK/supabase/.temp/project-ref" 2>/dev/null)" = "$STAGING_REF" ] || { echo "Run scripts/staging/db_push.sh --apply first (it links the staging folder)."; exit 2; }

case "${1:-}" in
  --deploy)
    echo "Deploying livekit-token to STAGING $STAGING_REF (production $PROD_REF is not touched)"
    supabase functions deploy livekit-token --project-ref "$STAGING_REF" --workdir "$WORK" --use-api 2>&1 | grep -E "Deployed|Error|error|WARN" | head -5
    ;;
  --secrets)
    [ -f "$LK_FILE" ] || { echo "Missing $LK_FILE. Create it (chmod 600) with these three lines, values from your LiveCore account:"; printf '  LIVEKIT_URL=wss://...\n  LIVEKIT_API_KEY=...\n  LIVEKIT_API_SECRET=...\n'; exit 2; }
    perm=$(stat -f '%Lp' "$LK_FILE" 2>/dev/null || stat -c '%a' "$LK_FILE")
    [ "$perm" = "600" ] || { echo "$LK_FILE must be mode 600 (chmod 600 $LK_FILE)."; exit 2; }
    set -a; . "$LK_FILE"; set +a
    # the file may name them LIVECORE_* (the vendor's name) or LIVEKIT_*: either works
    LIVEKIT_URL="${LIVEKIT_URL:-${LIVECORE_URL:-}}"; LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-${LIVECORE_API_KEY:-}}"; LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-${LIVECORE_API_SECRET:-}}"
    : "${LIVEKIT_URL:?LIVEKIT_URL missing in $LK_FILE}" "${LIVEKIT_API_KEY:?LIVEKIT_API_KEY missing}" "${LIVEKIT_API_SECRET:?LIVEKIT_API_SECRET missing}"
    case "$LIVEKIT_URL" in wss://*) ;; *) echo "LIVEKIT_URL must start with wss://"; exit 2;; esac
    supabase secrets set LIVEKIT_URL="$LIVEKIT_URL" LIVEKIT_API_KEY="$LIVEKIT_API_KEY" LIVEKIT_API_SECRET="$LIVEKIT_API_SECRET" --project-ref "$STAGING_REF" >/dev/null 2>&1 \
      && echo "ok: the three LiveKit secrets are set on STAGING (values not shown)" || { echo "FAILED to set the secrets (wrong login?)"; exit 1; }
    ;;
  --check)
    code=$(curl -s -o /tmp/lk_check.json -w '%{http_code}' -X POST "$STAGING_URL/functions/v1/livekit-token" -H "apikey: ${STAGING_PUBLISHABLE_KEY:-$STAGING_ANON_KEY}" -H "Authorization: Bearer ${STAGING_ANON_KEY}" -H 'Content-Type: application/json' -d '{"channelName":"x"}')
    echo "HTTP $code: $(head -c 200 /tmp/lk_check.json; echo)"; rm -f /tmp/lk_check.json
    ;;
  *) sed -n 2,9p "$0"; exit 2;;
esac
