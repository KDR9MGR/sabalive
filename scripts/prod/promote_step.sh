#!/usr/bin/env bash
# Promote ONE migration to the linked project, with a safety net around it. Built for the staging -> production release
# (docs/PROMOTION_2026-10.md); the same script rehearses itself on staging.
#
#   scripts/prod/promote_step.sh <version>                         # DRY RUN: shows what it would do, changes nothing
#   PROMOTE_CONFIRM=<version> scripts/prod/promote_step.sh <version> --apply
#   PROMOTE_CONFIRM=<version> scripts/prod/promote_step.sh <version> --apply --record-only   # objects already there (hand-applied)
#   ... --staging            rehearse on STAGING (its own link folder; production is never touched)
#   ... --any-hour           allow outside the quiet window 21:00-04:00 UTC (only for additive "tier A" files)
#   ... --replay             also replay every migration on a scratch Postgres first (needs postgresql@15+)
#
# What it does, in order (and stops at the first problem):
#   1. finds the migration and its down script (supabase/rollbacks/<version>*_down.sql); refuses if either is missing
#   2. says WHICH project it will touch, and refuses production unless the link folder really is production
#   3. checks the version is still pending on that project
#   4. production only: inside the quiet window (unless --any-hour), and a backup less than 6 hours old exists
#   5. baseline: scripts/prod/healthcheck.sh has no FAIL and scripts/prod/smoke_play_app.sh passes
#   6. applies the file in ONE transaction with lock_timeout 5s (`supabase db query --linked -f`), then records it
#      (`supabase migration repair --status applied`), exactly how the Lucky Box pull back was shipped
#   7. reruns healthcheck + smoke; on a FAIL it prints the down script and how to run it, and exits 1
#
# It never runs `supabase db push` (that applies EVERYTHING pending, including work nobody reviewed), never deploys
# functions, and with --apply it needs PROMOTE_CONFIRM=<version> typed on purpose: only run it after the owner says "go".
set -uo pipefail
cd "$(dirname "$0")/../.."    # the sabalive/ app repo

VERSION="${1:-}"
[ -n "$VERSION" ] && shift || true
APPLY=0; RECORD_ONLY=0; STAGING=0; ANY_HOUR=0; REPLAY=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1;; --record-only) RECORD_ONLY=1;; --staging) STAGING=1;; --any-hour) ANY_HOUR=1;; --replay) REPLAY=1;;
    *) echo "unknown option: $a"; exit 2;;
  esac
done
if ! echo "$VERSION" | grep -qE '^[0-9]{14}$'; then
  sed -n 2,26p "$0" | sed 's/^# \{0,1\}//'; exit 2
fi
command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }

say() { printf '%s\n' "$*"; }
die() { printf 'STOP: %s\n' "$*"; exit 1; }

# ---- 1. the files
FILE=$(ls supabase/migrations/${VERSION}_*.sql 2>/dev/null | head -2)
[ -n "$FILE" ] && [ "$(echo "$FILE" | wc -l)" -eq 1 ] || die "need exactly one supabase/migrations/${VERSION}_*.sql"
DOWN=$(ls supabase/rollbacks/${VERSION}*_down.sql 2>/dev/null | head -1)
[ -n "$DOWN" ] || die "no down script supabase/rollbacks/${VERSION}*_down.sql (every migration needs a way back)"

# ---- 2. which project
PROD_REF=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
if [ "$STAGING" -eq 1 ]; then
  ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
  [ -f "$ENV_FILE" ] || die "missing $ENV_FILE (see docs/STAGING.md)"
  set -a; . "$ENV_FILE"; set +a
  : "${STAGING_REF:?}" "${STAGING_URL:?}" "${STAGING_PUBLISHABLE_KEY:?}"
  [ "$STAGING_REF" != "$PROD_REF" ] || die "STAGING_REF is the production project"
  export SUPABASE_WORKDIR="${STAGING_WORKDIR:-$HOME/.sabalive-staging-workdir}"
  export SABALIVE_API_URL="$STAGING_URL" SABALIVE_API_KEY="$STAGING_PUBLISHABLE_KEY"
  TARGET_REF="$STAGING_REF"; TARGET_NAME="STAGING"
else
  [ -z "${SUPABASE_WORKDIR:-}" ] || die "SUPABASE_WORKDIR is set (another project's link folder): unset it to target production, or use --staging"
  TARGET_REF=$(cat supabase/.temp/project-ref 2>/dev/null || echo "")
  [ "$TARGET_REF" = "$PROD_REF" ] || die "this folder is linked to '${TARGET_REF:-nothing}', not production ($PROD_REF)"
  TARGET_NAME="PRODUCTION"
fi
[ "$(cat "${SUPABASE_WORKDIR:-.}/supabase/.temp/project-ref" 2>/dev/null)" = "$TARGET_REF" ] || die "the link folder is not linked to $TARGET_REF"
sb() { supabase ${SUPABASE_WORKDIR:+--workdir "$SUPABASE_WORKDIR"} "$@"; }

say "================================================================"
say " $TARGET_NAME ($TARGET_REF)   migration $VERSION"
say " file: $FILE"
say " down: $DOWN"
say " mode: $([ "$APPLY" -eq 1 ] && echo APPLY || echo 'DRY RUN (nothing will change)')$([ "$RECORD_ONLY" -eq 1 ] && echo ', record only')"
say "================================================================"

# ---- 3. still pending?
LIST=$(sb migration list 2>/dev/null)
ROW=$(echo "$LIST" | grep -E "(^|[^0-9])${VERSION}([^0-9]|$)" | head -1)
[ -n "$ROW" ] || die "$VERSION is not in the migration list (is the file committed under supabase/migrations?)"
REMOTE=$(echo "$ROW" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
if [ -n "$REMOTE" ]; then say "Already recorded as applied on $TARGET_NAME: nothing to do."; exit 0; fi
say "PASS  $VERSION is pending on $TARGET_NAME"

# ---- the file must be safe to wrap in one transaction
if grep -qiE '^[[:space:]]*(begin|commit)[[:space:]]*;' "$FILE" && [ "$RECORD_ONLY" -eq 0 ]; then
  die "$FILE has its own begin/commit: run it by hand, this script wraps files in one transaction itself"
fi

# ---- 4. production only: quiet window and a fresh backup
if [ "$STAGING" -eq 0 ]; then
  HOUR=$(date -u +%H); HOUR=$((10#$HOUR))
  if [ "$HOUR" -ge 21 ] || [ "$HOUR" -lt 4 ]; then say "PASS  inside the quiet window (21:00-04:00 UTC), now $(date -u +%H:%M) UTC"
  elif [ "$ANY_HOUR" -eq 1 ]; then say "WARN  outside the quiet window (now $(date -u +%H:%M) UTC): allowed by --any-hour"
  else die "now is $(date -u +%H:%M) UTC, outside the quiet window 21:00-04:00 UTC (use --any-hour only for additive tier-A files)"; fi

  ROOT="${SABALIVE_BACKUP_DIR:-$HOME/sabalive-backups}"
  LATEST=$(ls -1 "$ROOT" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | tail -1)
  [ -n "$LATEST" ] || die "no backup in $ROOT: run scripts/prod/backup.sh first"
  T=$(echo "$LATEST" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$/\1-\2-\3 \4:\5:\6/')
  AGE=$(( $(date -u +%s) - $(date -u -j -f '%Y-%m-%d %H:%M:%S' "$T" +%s 2>/dev/null || date -u -d "$T" +%s) ))
  [ "$AGE" -lt 21600 ] || die "newest backup ($LATEST) is $((AGE / 3600)) h old: run scripts/prod/backup.sh again (BACKUP OK) first"
  grep -q 'ok\|OK\|rows' "$ROOT/$LATEST/MANIFEST.txt" 2>/dev/null || die "backup $LATEST has no MANIFEST.txt: it did not finish"
  say "PASS  backup $LATEST is $((AGE / 60)) min old"
fi

# ---- optional replay
if [ "$REPLAY" -eq 1 ]; then
  scripts/db/replay_migrations.sh | tail -3 | grep -q ALL_OK || die "replay_migrations.sh did not end with ALL_OK"
  say "PASS  replay of every migration: ALL_OK"
fi

# ---- 5. baseline
say; say "Baseline (before)"
HC=$(scripts/prod/healthcheck.sh 2>&1); HC_RC=$?
echo "$HC" | grep -E 'FAIL|WARN' || true
[ "$HC_RC" -eq 0 ] || die "the health check has a FAIL: do not change a database that is already unhealthy"
say "PASS  health check has no FAIL"
SM=$(scripts/prod/smoke_play_app.sh 2>&1); SM_RC=$?
echo "$SM" | grep -E 'FAIL|RESULT' || true
[ "$SM_RC" -eq 0 ] || die "the Play-app smoke test fails before the change"
say "PASS  Play-app smoke test"

if [ "$APPLY" -ne 1 ]; then
  say; say "DRY RUN finished. To apply: PROMOTE_CONFIRM=$VERSION $0 $VERSION --apply$([ "$STAGING" -eq 1 ] && echo ' --staging')$([ "$RECORD_ONLY" -eq 1 ] && echo ' --record-only')"
  exit 0
fi
[ "${PROMOTE_CONFIRM:-}" = "$VERSION" ] || die "--apply needs PROMOTE_CONFIRM=$VERSION in the environment (only after the owner says go)"

# ---- 6. apply + record
if [ "$RECORD_ONLY" -eq 0 ]; then
  say; say "Applying $FILE ..."
  TMP=$(mktemp -t promote_step.XXXXXX)
  { echo "begin;"; echo "set local lock_timeout = '5s';"; cat "$FILE"; printf '\ncommit;\n'; } > "$TMP"
  if ! OUT=$(sb db query --linked -f "$TMP" 2>&1); then
    rm -f "$TMP"
    echo "$OUT" | tail -8
    die "the migration FAILED and was rolled back by Postgres (one transaction): nothing changed. Fix it on staging first."
  fi
  rm -f "$TMP"
  say "PASS  applied"
fi
sb migration repair --status applied "$VERSION" 2>&1 | grep -v 'new version\|recommend' | tail -2
say "PASS  recorded as applied"

# ---- 7. after
say; say "After"
HC=$(scripts/prod/healthcheck.sh 2>&1); HC_RC=$?
echo "$HC" | grep -E 'FAIL|WARN' || true
SM=$(scripts/prod/smoke_play_app.sh 2>&1); SM_RC=$?
echo "$SM" | grep -E 'FAIL|RESULT' || true
if [ "$HC_RC" -ne 0 ] || [ "$SM_RC" -ne 0 ]; then
  say
  say "SOMETHING FAILED AFTER $VERSION. Look first (healthcheck, smoke output above). To undo this migration:"
  say "  $( [ "$STAGING" -eq 1 ] && echo 'SUPABASE_WORKDIR=$HOME/.sabalive-staging-workdir ' )supabase ${SUPABASE_WORKDIR:+--workdir \"\$SUPABASE_WORKDIR\" }db query --linked -f \"$PWD/$DOWN\""
  say "  supabase migration repair --status reverted $VERSION      (only if a later push should apply it again)"
  exit 1
fi
say
say "DONE: $VERSION is live on $TARGET_NAME. Watch lives/joins for 15 minutes, note it in the QA tracker, and rerun healthcheck.sh in a while."
