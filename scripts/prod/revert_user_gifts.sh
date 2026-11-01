#!/usr/bin/env bash
# Undo every gift one person SENT or RECEIVED in a time window, so the database looks as if those gifts were never sent (the sender gets the coins back, the receiver loses the
# diamonds, the gift rows and their wallet ledger rows are removed so rankings, Salary and the diamond reset no longer count them, XP and levels go down by the same amount,
# the live's gift total goes down). Made for a TEST account's gifts.
#
#   scripts/prod/revert_user_gifts.sh 101427 --from "2026-11-01 20:30:00+00" --to "2026-11-01 21:30:00+00"           # PLAN ONLY: counts, who gets what back, blockers; writes nothing
#   ... --apply        does it (production: needs a backup under 6 h old, a clean healthcheck, a plan without blockers, and you typing the User ID, or REVERT_CONFIRM=<User ID>)
#   scripts/prod/revert_user_gifts.sh 101427 --undo ~/sabalive-backups/gift-revert-101427-<stamp>.json              # puts exactly that apply back (--apply prints the file name)
#   SUPABASE_WORKDIR=$HOME/.sabalive-staging-workdir scripts/prod/revert_user_gifts.sh <a staging User ID> --from ... --to ... --apply     # rehearse on STAGING first
#
# The window is a pair of UTC times (from inclusive, to exclusive); both are required, there is no default. One transaction: any blocker or error and nothing is kept.
# A BLOCKER (the apply refuses): no gifts in the window, a wallet ledger row that does not match a gift exactly, a receiver who no longer holds the diamonds (a wallet cannot go
# below 0), XP that would go below 0. Anything the plan lists is exactly what the apply does.
# The SQL is scripts/prod/revert_user_gifts_{plan,apply,undo}.sql; scripts/db/tests/revert_user_gifts_test.sql proves it on a scratch database, with the real gift functions.
# Only run --apply / --undo on PRODUCTION after the owner says go (CLAUDE.md > Production safety).
set -uo pipefail
cd "$(dirname "$0")/../.."    # sabalive/
. scripts/lib/supabase_login.sh
command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 2; }

usage() { sed -n 2,13p "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ID="${1:-}"; [ -n "$ID" ] && shift || true
[[ "$ID" =~ ^[0-9]{3,12}$ ]] || usage
MODE=plan; FROM=""; TO=""; PACK=""
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\+00$'
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2;;
    --to) TO="${2:-}"; shift 2;;
    --apply) MODE=apply; shift;;
    --undo) MODE=undo; PACK="${2:-}"; shift 2;;
    *) echo "unknown option: $1"; usage;;
  esac
done
if [ "$MODE" != "undo" ]; then
  [[ "$FROM" =~ $TS_RE ]] && [[ "$TO" =~ $TS_RE ]] || { echo "--from and --to are required, like \"2026-11-01 20:30:00+00\" (UTC)"; usage; }
  [[ "$FROM" < "$TO" ]] || { echo "--from must be earlier than --to"; exit 2; }
fi

sb() { supabase ${SUPABASE_WORKDIR:+--workdir "$SUPABASE_WORKDIR"} "$@"; }
LINKED=$(cat "${SUPABASE_WORKDIR:-.}/supabase/.temp/project-ref" 2>/dev/null || echo unknown)
PROD_REF=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
[ "$LINKED" != "unknown" ] || { echo "STOP: no linked project"; exit 1; }
IS_PROD=0; [ "$LINKED" = "$PROD_REF" ] && IS_PROD=1
die() { echo "STOP: $1" >&2; exit 1; }
say() { printf '  %s\n' "$1"; }

# the SQL with the User ID (digits only, checked above), the window (checked above) and, for the undo, the pack put in; the file is private and removed afterwards
run_sql() {  # $1 = sql file
  local tmp; tmp=$(mktemp); chmod 600 "$tmp"
  python3 scripts/prod/revert_user_gifts_fill.py "$1" "$ID" "${FROM:-1970-01-01 00:00:00+00}" "${TO:-1970-01-01 00:00:01+00}" "$PACK" > "$tmp" || { rm -f "$tmp"; return 1; }
  sb db query --linked -o json -f "$tmp"; local rc=$?
  rm -f "$tmp"; return $rc
}
# the answer is one row with a `plan` or `report` value; look for it wherever the CLI put it. The CLI may print lines before and after the JSON ("Initialising login role...",
# an update notice), so the JSON is cut out of the text first.
report() {
  python3 -c '
import json, sys
text = sys.stdin.read()
try:
    obj, _ = json.JSONDecoder().raw_decode(text[text.index("{"):])
except Exception:
    sys.exit(0)
def find(o):
    if isinstance(o, dict):
        for k in ("plan", "report"):
            if k in o:
                return o[k]
        for v in o.values():
            r = find(v)
            if r is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            r = find(v)
            if r is not None:
                return r
r = find(obj)
if r is not None:
    print(json.dumps(r))
'
}

show_plan() {  # $1 = the plan json
  echo "$1" | jq -r '"  gifts in the window ....... \(.gifts) (\(.coins) coins): sent by \($id) \(.sent_by_target), received by \($id) \(.received_by_target), to itself \(.self_gifts)\n  from \(.first_gift_at) to \(.last_gift_at)\n  wallet ledger rows matched .. gift_sent \(.ledger_sent_matched), gift_received \(.ledger_received_matched) (each must equal the gift count)\n  live streams touched ....... \(.streams)"' --arg id "$ID"
  echo "  accounts (User ID: coins back | diamonds taken | diamonds held now):"
  echo "$1" | jq -r '.accounts[] | "    \(.user_id): +\(.coins_back) coins | -\(.diamonds_out) diamonds | holds \(.diamonds_now)"'
  local nb; nb=$(echo "$1" | jq '.blockers | length')
  if [ "$nb" -gt 0 ]; then echo "  BLOCKERS ($nb):"; echo "$1" | jq -r '.blockers[] | "    - " + .'; else echo "  no blockers"; fi
}

echo "Revert gifts  |  User ID $ID  |  project $LINKED $([ $IS_PROD -eq 1 ] && echo '(PRODUCTION)' || echo '(not production)')  |  mode: $MODE"

get_plan() {
  local out p
  out=$(run_sql scripts/prod/revert_user_gifts_plan.sql 2>&1) || { echo "$out" | tail -5 >&2; die "could not read the database"; }
  p=$(echo "$out" | report); [ -n "$p" ] && [ "$p" != "null" ] || { echo "$out" | tail -5 >&2; die "no answer"; }
  echo "$p"
}

if [ "$MODE" = "plan" ]; then
  P=$(get_plan) || exit 1
  [ "$(echo "$P" | jq .target_found)" = "1" ] || die "no account has User ID $ID"
  [ "$(echo "$P" | jq .target_is_ghost)" = "0" ] || die "User ID $ID is a monitoring account: never use it"
  echo "  window (UTC): $FROM to $TO"
  show_plan "$P"
  echo
  echo "Nothing was changed. To do it: $0 $ID --from \"$FROM\" --to \"$TO\" --apply"
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
  P=$(get_plan) || exit 1
  [ "$(echo "$P" | jq .target_found)" = "1" ] || die "no account has User ID $ID"
  [ "$(echo "$P" | jq .target_is_ghost)" = "0" ] || die "User ID $ID is a monitoring account: never use it"
  show_plan "$P"
  [ "$(echo "$P" | jq '.blockers | length')" -eq 0 ] || die "the plan has blockers: nothing was changed"
  if [ -n "${REVERT_CONFIRM:-}" ]; then CONFIRM="$REVERT_CONFIRM"; else read -r -p "  Type the User ID again to go ahead: " CONFIRM; fi
  [ "$CONFIRM" = "$ID" ] || die "not confirmed, nothing was changed"
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  DIR="${SABALIVE_BACKUP_DIR:-$HOME/sabalive-backups}"; mkdir -p "$DIR"; chmod 700 "$DIR" 2>/dev/null || true
  PACKOUT="$DIR/gift-revert-$ID-$STAMP.json"
  OUT=$(run_sql scripts/prod/revert_user_gifts_apply.sql 2>&1); RC=$?
  R=$(echo "$OUT" | report)
  if [ $RC -ne 0 ] || [ -z "$R" ] || [ "$R" = "null" ]; then echo "$OUT" | tail -8; die "it did not finish. It is one transaction, so nothing was kept. Run the plan again to check."; fi
  ( umask 077; echo "$R" | jq '.pack' > "$PACKOUT" )
  echo "$R" | jq -r '"  DONE  \(.gifts_undone) gifts (\(.coins) coins) undone, \(.accounts_changed) accounts changed, \(.ledger_rows_removed) ledger rows removed"'
  say "everything that was removed is saved in $PACKOUT (private; keep it)"
  AFTER=$(get_plan); say "plan again now: $(echo "$AFTER" | jq .gifts) gifts left in the window (expect 0)"
  echo
  echo "To put it all back:  $0 $ID --undo \"$PACKOUT\""
  exit 0
fi

# undo
[ -f "$PACK" ] || die "--undo needs the pack file that --apply saved"
[ "$(jq '.gifts | length' "$PACK" 2>/dev/null)" -gt 0 ] 2>/dev/null || die "that file is not a pack"
[ "$(jq -r .target "$PACK")" = "$ID" ] || die "that pack is for User ID $(jq -r .target "$PACK"), not $ID"
if [ "$IS_PROD" -eq 1 ]; then
  if [ -n "${REVERT_CONFIRM:-}" ]; then CONFIRM="$REVERT_CONFIRM"; else read -r -p "  This puts $(jq '.gifts | length' "$PACK") gifts back on PRODUCTION. Type the User ID to go ahead: " CONFIRM; fi
  [ "$CONFIRM" = "$ID" ] || die "not confirmed, nothing was changed"
fi
OUT=$(run_sql scripts/prod/revert_user_gifts_undo.sql 2>&1); RC=$?
R=$(echo "$OUT" | report)
if [ $RC -ne 0 ] || [ -z "$R" ] || [ "$R" = "null" ]; then echo "$OUT" | tail -8; die "it did not finish; nothing was kept"; fi
echo "$R" | jq -r '"  UNDONE  \(.gifts_restored) gifts and \(.ledger_rows_restored) ledger rows put back, \(.accounts_changed) accounts changed"'
