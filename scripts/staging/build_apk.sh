#!/usr/bin/env bash
# Build a STAGING test APK: it talks to the staging Supabase project, never to production, and shows an
# orange STAGING ribbon on every screen.
#
#   scripts/staging/build_apk.sh
#
# Reads ~/sabalive-secrets/staging.env (outside the repo; see docs/STAGING.md):
#   STAGING_URL=https://xxxxxxxx.supabase.co
#   STAGING_PUBLISHABLE_KEY=sb_publishable_...
# The app itself also refuses to start if a staging build points at production (AppEnvironment.validate).
set -euo pipefail
cd "$(dirname "$0")/../.."

ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_URL:?STAGING_URL missing in $ENV_FILE}" "${STAGING_PUBLISHABLE_KEY:?STAGING_PUBLISHABLE_KEY missing in $ENV_FILE}"

PROD_URL=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE 'https://[a-z0-9]+\.supabase\.co')
if [ "$STAGING_URL" = "$PROD_URL" ]; then echo "STAGING_URL is the production address. Refusing."; exit 2; fi

VERSION=$(grep -E '^version:' pubspec.yaml | awk '{print $2}')
flutter clean >/dev/null
flutter build apk --release \
  --dart-define=SABALIVE_ENV=staging \
  --dart-define=SUPABASE_URL="$STAGING_URL" \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$STAGING_PUBLISHABLE_KEY"

OUT="${SABALIVE_RELEASES_DIR:-$HOME/sabalive-releases}/sabalive-staging-$VERSION.apk"
mkdir -p "$(dirname "$OUT")"
cp build/app/outputs/flutter-apk/app-release.apk "$OUT"
echo "STAGING APK: $OUT"
echo "It uses the same package name as the Play app, so a phone with the Play version must uninstall it first (or use another phone)."
