#!/usr/bin/env bash
# Apply the migrations in git to the STAGING project, through a separate link folder, so the production
# link in supabase/.temp is never touched and this can never push to production by accident.
#
#   scripts/staging/db_push.sh            # dry run: lists what would be applied
#   scripts/staging/db_push.sh --apply    # applies it
#
# Reads ~/sabalive-secrets/staging.env:  STAGING_REF=xxxxxxxx   STAGING_DB_PASSWORD=...
# NOTE: written ahead of the staging project existing; check the dry run output before using --apply.
set -euo pipefail
cd "$(dirname "$0")/../.."

ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_REF:?STAGING_REF missing in $ENV_FILE}" "${STAGING_DB_PASSWORD:?STAGING_DB_PASSWORD missing in $ENV_FILE}"

PROD_REF=$(cat supabase/.temp/project-ref 2>/dev/null || echo "")
PROD_URL_REF=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
if [ "$STAGING_REF" = "$PROD_REF" ] || [ "$STAGING_REF" = "$PROD_URL_REF" ]; then
  echo "STAGING_REF is the production project. Refusing."; exit 2
fi

WORK="${STAGING_WORKDIR:-$HOME/.sabalive-staging-workdir}"
mkdir -p "$WORK/supabase"
ln -sfn "$PWD/supabase/migrations" "$WORK/supabase/migrations"
ln -sfn "$PWD/supabase/functions" "$WORK/supabase/functions"
[ -f "$WORK/supabase/config.toml" ] || cp supabase/config.toml "$WORK/supabase/config.toml"

export SUPABASE_DB_PASSWORD="$STAGING_DB_PASSWORD"
supabase link --project-ref "$STAGING_REF" --workdir "$WORK" >/dev/null
LINKED=$(cat "$WORK/supabase/.temp/project-ref")
[ "$LINKED" = "$STAGING_REF" ] || { echo "Linked to $LINKED, expected $STAGING_REF. Stopping."; exit 2; }
echo "Staging project: $LINKED"

if [ "${1:-}" = "--apply" ]; then
  supabase db push --workdir "$WORK" --yes
else
  supabase db push --workdir "$WORK" --dry-run
  echo "(dry run: nothing applied. Run again with --apply.)"
fi
