#!/usr/bin/env bash
# Make EVERY real account follow one person AND that person follow every real account (so each pair are also Fans), once, silently (no notification, no push).
#
#   scripts/prod/follow_everyone.sh 101427                       # PLAN ONLY: counts, writes nothing (always run this first)
#   scripts/prod/follow_everyone.sh 101427 --apply               # does it (production: needs a backup under 6 h old, a clean healthcheck, and you typing the User ID)
#   scripts/prod/follow_everyone.sh 101427 --undo "<stamp>"      # removes exactly the follows that one --apply run added (the stamp is printed by --apply)
#   SUPABASE_WORKDIR=$HOME/.sabalive-staging-workdir scripts/prod/follow_everyone.sh <a staging User ID> --apply     # rehearse on STAGING first
#
# Left out: the person themselves, monitoring (ghost) accounts, panel staff, accounts that are not active, accounts under an active account / device ban,
# and anyone who blocked them or whom they blocked. Follows that already exist are kept as they are (and are not undone). One transaction: any error and nothing is kept.
# The SQL is scripts/prod/follow_everyone_{plan,apply,undo}.sql; scripts/db/tests/follow_everyone_test.sql proves it on a scratch database (22 checks).
# Only run --apply / --undo on PRODUCTION after the owner says go (CLAUDE.md > Production safety).
set -uo pipefail
cd "$(dirname "$0")/../.."    # sabalive/
. scripts/lib/supabase_login.sh
command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 2; }

ID="${1:-}"; [ -n "$ID" ] && shift || true
[[ "$ID" =~ ^[0-9]{3,12}$ ]] || { sed -n 2,9p "$0" | sed 's/^# \{0,1\}//'; exit 2; }
MODE=plan; STAMP=""
case "${1:-}" in
  "") ;;
  --apply) MODE=apply;;
  --undo) MODE=undo; STAMP="${2:-}"; [[ "$STAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9:]{8}\.[0-9]{6}\+00$ ]] || { echo "--undo needs the stamp --apply printed, like \"2026-10-31 11:22:33.123456+00\""; exit 2; };;
  *) echo "unknown option: $1"; exit 2;;
esac

sb() { supabase ${SUPABASE_WORKDIR:+--workdir "$SUPABASE_WORKDIR"} "$@"; }
LINKED=$(cat "${SUPABASE_WORKDIR:-.}/supabase/.temp/project-ref" 2>/dev/null || echo unknown)
PROD_REF=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
[ "$LINKED" != "unknown" ] || { echo "STOP: no linked project"; exit 1; }
IS_PROD=0; [ "$LINKED" = "$PROD_REF" ] && IS_PROD=1
die() { echo "STOP: $1"; exit 1; }
say() { printf '  %s\n' "$1"; }

# the SQL with the User ID (digits only, checked above) and the stamp put in
run_sql() {  # $1 = file
  local tmp; tmp=$(mktemp); chmod 600 "$tmp"
  sed -e "s/__DISPLAY_ID__/$ID/g" -e "s/__STAMP__/$STAMP/g" "$1" > "$tmp"
  sb db query --linked -o json -f "$tmp"; local rc=$?
  rm -f "$tmp"; return $rc
}
# the answer is one row with a `plan` or `report` value; look for it wherever the CLI put it (one result, or one per statement)
report() { jq -r '[.. | objects | select(has("plan") or has("report")) | (.plan // .report)] | first // empty' 2>/dev/null; }

echo "Follow everyone  |  User ID $ID  |  project $LINKED $([ $IS_PROD -eq 1 ] && echo '(PRODUCTION)' || echo '(not production)')  |  mode: $MODE"

if [ "$MODE" = "plan" ]; then
  OUT=$(run_sql scripts/prod/follow_everyone_plan.sql 2>&1) || { echo "$OUT" | tail -5; die "could not read the database"; }
  P=$(echo "$OUT" | report); [ -n "$P" ] && [ "$P" != "null" ] || { echo "$OUT" | tail -5; die "no answer"; }
  [ "$(echo "$P" | jq .target_found)" = "1" ] || die "no account has User ID $ID"
  [ "$(echo "$P" | jq .target_is_ghost)" = "0" ] || die "User ID $ID is a monitoring account: never use it"
  echo "  accounts in total ............ $(echo "$P" | jq .accounts_in_total)"
  echo "  eligible (real, active) ...... $(echo "$P" | jq .eligible)"
  echo "  would ADD 'follows $ID' ...... $(echo "$P" | jq .will_add_everyone_follows_target)"
  echo "  would ADD '$ID follows' ...... $(echo "$P" | jq .will_add_target_follows_everyone)"
  echo "  left out: ghosts $(echo "$P" | jq .left_out_ghosts), staff $(echo "$P" | jq .left_out_staff), not active $(echo "$P" | jq .left_out_not_active) (plus banned / blocked)"
  echo "  $ID today: $(echo "$P" | jq .target_followers_now) followers, $(echo "$P" | jq .target_following_now) following"
  echo
  echo "Nothing was changed. To do it: $0 $ID --apply"
  exit 0
fi

if [ "$MODE" = "apply" ]; then
  if [ "$IS_PROD" -eq 1 ]; then
    ROOT="${SABALIVE_BACKUP_DIR:-$HOME/sabalive-backups}"
    LATEST=$(ls -1 "$ROOT" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | tail -1)
    [ -n "$LATEST" ] || die "no backup in $ROOT: run scripts/prod/backup.sh first"
    T=$(echo "$LATEST" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$/\1-\2-\3 \4:\5:\6/')
    AGE=$(( $(date -u +%s) - $(date -u -j -f '%Y-%m-%d %H:%M:%S' "$T" +%s 2>/dev/null || date -u -d "$T" +%s) ))
    [ "$AGE" -lt 21600 ] || die "newest backup ($LATEST) is $((AGE / 3600)) h old: run scripts/prod/backup.sh again (BACKUP OK) first"
    grep -q 'ok\|OK\|rows' "$ROOT/$LATEST/MANIFEST.txt" 2>/dev/null || die "backup $LATEST has no MANIFEST.txt: it did not finish"
    say "PASS  backup $LATEST is $((AGE / 60)) min old"
    scripts/prod/healthcheck.sh >/dev/null 2>&1 || die "scripts/prod/healthcheck.sh is not clean: look at it first"
    say "PASS  healthcheck is clean"
  fi
  PLAN=$(run_sql scripts/prod/follow_everyone_plan.sql 2>&1 | report)
  [ -n "$PLAN" ] && [ "$PLAN" != "null" ] || die "could not read the plan"
  [ "$(echo "$PLAN" | jq .target_found)" = "1" ] || die "no account has User ID $ID"
  [ "$(echo "$PLAN" | jq .target_is_ghost)" = "0" ] || die "User ID $ID is a monitoring account: never use it"
  say "This will add $(echo "$PLAN" | jq .will_add_everyone_follows_target) + $(echo "$PLAN" | jq .will_add_target_follows_everyone) follows for User ID $ID, silently."
  read -r -p "  Type the User ID again to go ahead: " CONFIRM
  [ "$CONFIRM" = "$ID" ] || die "not confirmed, nothing was changed"
  STAMP=$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f+00"))')
  OUT=$(run_sql scripts/prod/follow_everyone_apply.sql 2>&1); RC=$?
  R=$(echo "$OUT" | report)
  if [ $RC -ne 0 ] || [ -z "$R" ] || [ "$R" = "null" ]; then echo "$OUT" | tail -8; die "it did not finish. It is one transaction, so nothing was kept. Run the plan again to check."; fi
  echo "$R" | jq -r '"  DONE  added: everyone follows \(.added_everyone_follows_target) | \(.added_target_follows_everyone) follows everyone\n  now: \(.target_followers_now) followers, \(.target_following_now) following, \(.target_fans_now) fans\n  counters that disagree with the follows table: \(.counters_that_disagree_with_follows)"'
  echo
  echo "To take exactly this back:  $0 $ID --undo \"$STAMP\""
  exit 0
fi

# undo
if [ "$IS_PROD" -eq 1 ]; then
  read -r -p "  This removes the follows made at $STAMP on PRODUCTION. Type the User ID to go ahead: " CONFIRM
  [ "$CONFIRM" = "$ID" ] || die "not confirmed, nothing was changed"
fi
OUT=$(run_sql scripts/prod/follow_everyone_undo.sql 2>&1); RC=$?
R=$(echo "$OUT" | report)
if [ $RC -ne 0 ] || [ -z "$R" ] || [ "$R" = "null" ]; then echo "$OUT" | tail -8; die "it did not finish; nothing was kept"; fi
echo "$R" | jq -r '"  UNDONE  rows left with that stamp: \(.rows_left_with_this_stamp)\n  now: \(.target_followers_now) followers, \(.target_following_now) following, \(.target_fans_now) fans"'
