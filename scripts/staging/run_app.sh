#!/usr/bin/env bash
# Run the app on a connected phone / emulator pointed at STAGING (never production), with hot reload (r) and hot restart (R).
#
#   scripts/staging/run_app.sh              # the one connected device (flutter asks if there are several)
#   scripts/staging/run_app.sh -d <device>  # extra flutter arguments are passed on
#
# A plain `flutter run` is PRODUCTION (the app defaults to the live project). This reads ~/sabalive-secrets/staging.env (outside the repo, see
# docs/STAGING.md) and passes the same flags scripts/staging/build_apk.sh does; the app itself refuses to start if the environment name and the
# Supabase address disagree, and shows the orange STAGING ribbon on every screen.
set -euo pipefail
cd "$(dirname "$0")/../.."

ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_URL:?STAGING_URL missing in $ENV_FILE}" "${STAGING_PUBLISHABLE_KEY:?STAGING_PUBLISHABLE_KEY missing in $ENV_FILE}"

PROD_URL=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE 'https://[a-z0-9]+\.supabase\.co')
if [ "$STAGING_URL" = "$PROD_URL" ]; then echo "STAGING_URL is the production address. Refusing."; exit 2; fi

# the separate staging Agora project, when staging.env has one (without it live video cannot start on staging)
AGORA_ARG=""
[ -n "${STAGING_AGORA_APP_ID:-}" ] && AGORA_ARG="--dart-define=AGORA_APP_ID=$STAGING_AGORA_APP_ID"

echo "Running against STAGING ($STAGING_URL). Look for the orange STAGING ribbon."
# RTC_PROVIDER=livekit: the lives this run starts use MS cloud (the hosted LiveKit server); STAGING_RTC_PROVIDER=agora keeps Agora
RTC_ARG="--dart-define=RTC_PROVIDER=${STAGING_RTC_PROVIDER:-livekit}"
exec flutter run \
  --dart-define=SABALIVE_ENV=staging $RTC_ARG \
  --dart-define=SUPABASE_URL="$STAGING_URL" \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$STAGING_PUBLISHABLE_KEY" $AGORA_ARG "$@"
