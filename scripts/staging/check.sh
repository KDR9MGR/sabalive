#!/usr/bin/env bash
# Run the production health check and the Play-app smoke test against STAGING.
#   scripts/staging/check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_URL:?}" "${STAGING_PUBLISHABLE_KEY:?}"
export SABALIVE_API_URL="$STAGING_URL" SABALIVE_API_KEY="$STAGING_PUBLISHABLE_KEY"
export SUPABASE_WORKDIR="${STAGING_WORKDIR:-$HOME/.sabalive-staging-workdir}"
rc=0
scripts/prod/healthcheck.sh || rc=1
echo
scripts/prod/smoke_play_app.sh || rc=1
exit $rc
