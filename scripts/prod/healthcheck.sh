#!/usr/bin/env bash
# Is production healthy? Run it BEFORE a push (to know the starting point) and right AFTER one.
#
# Read-only: it calls the same public status endpoint the app calls, then asks the linked
# database a handful of small questions. Prints PASS / WARN / FAIL lines; exits 1 on any FAIL.
#
#   scripts/prod/healthcheck.sh            # check the linked project
#
# Needs: supabase CLI (logged in + linked), jq, curl.
set -uo pipefail

cd "$(dirname "$0")/../.."    # the sabalive/ app repo

command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }

# the same public URL and publishable key the app ships with
URL=$(grep -E "static const String url" lib/config/supabase_config.dart | sed -E "s/.*'([^']+)'.*/\1/")
KEY=$(grep -A1 -E "static const String anonKey|static const String publishableKey" lib/config/supabase_config.dart | grep -oE "sb_publishable_[A-Za-z0-9_-]+|eyJ[A-Za-z0-9._-]+" | head -1)
LINKED=$(cat supabase/.temp/project-ref 2>/dev/null || echo "")
if [ -z "$URL" ] || [ -z "$KEY" ]; then echo "Could not read the API URL / key from lib/config/supabase_config.dart"; exit 2; fi

FAILS=0; WARNS=0
pass() { printf '  PASS  %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; WARNS=$((WARNS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

echo "Production health check  ($(date -u +%Y-%m-%d\ %H:%M:%S) UTC)"
echo "Project: ${LINKED:-unknown}   API: $URL"
case "$URL" in *"$LINKED"*) ;; *) [ -n "$LINKED" ] && warn "the linked project ($LINKED) is not the one in supabase_config.dart: are you checking the right one?";; esac

echo
echo "1. What users see"
BODY=$(mktemp)
CODE=$(curl -s -m 15 -o "$BODY" -w '%{http_code} %{time_total}' -X POST "$URL/rest/v1/rpc/get_system_status" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{}') || CODE="000 15"
HTTP=${CODE%% *}; SECS=${CODE##* }
if [ "$HTTP" != "200" ]; then
  fail "status call returned HTTP $HTTP after ${SECS}s (the app cannot reach the backend)"
else
  pass "status call answered in ${SECS}s"
  STATUS=$(jq -r '.status // "unknown"' "$BODY" 2>/dev/null)
  LOCK=$(jq -r '.lock_app // false' "$BODY" 2>/dev/null)
  BLOCK=$(jq -r '.block_logins // false' "$BODY" 2>/dev/null)
  if [ "$STATUS" = "online" ]; then pass "app status: online"
  else warn "app status: $STATUS (lock_app=$LOCK, block_logins=$BLOCK): users are locked out until it is ended in the panel"; fi
  # slow is a warning, not a failure
  awk "BEGIN{exit !($SECS > 2.0)}" && warn "status call took ${SECS}s (normally well under 1s)"
fi
rm -f "$BODY"
AUTH=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$URL/auth/v1/health" -H "apikey: $KEY") || AUTH="000"
[ "$AUTH" = "200" ] && pass "Auth is healthy" || fail "Auth health returned HTTP $AUTH (people cannot log in)"

echo
echo "2. The database"
Q=$(supabase db query --linked -o json "select
    (select count(*) from pg_stat_activity)::int as connections,
    current_setting('max_connections')::int as max_connections,
    (select count(*) from pg_stat_activity where state = 'active' and backend_type = 'client backend' and pid <> pg_backend_pid())::int as active,
    (select coalesce(max(extract(epoch from now() - query_start)), 0) from pg_stat_activity
       where state = 'active' and backend_type = 'client backend' and pid <> pg_backend_pid())::int as longest_query_s,
    (select count(*) from pg_stat_activity where wait_event_type = 'Lock')::int as waiting_on_locks,
    (select extract(epoch from now() - pg_postmaster_start_time())/60)::int as minutes_since_start,
    (select count(*) from cron.job_run_details where status = 'failed' and start_time > now() - interval '15 minutes')::int as cron_failed_15m,
    (select count(*) from cron.job_run_details where status = 'succeeded' and start_time > now() - interval '15 minutes')::int as cron_ok_15m,
    (select pg_size_pretty(pg_database_size(current_database()))) as db_size,
    (select count(*) from live_streams where status = 'live')::int as lives_now,
    (select coalesce(extract(epoch from now() - max(joined_at))/60, 99999) from live_stream_viewers)::int as minutes_since_last_join" 2>/dev/null | jq -c '.rows[0]')
if [ -z "$Q" ] || [ "$Q" = "null" ]; then
  fail "could not query the database through the CLI (it times out when the database is down)"
else
  n() { echo "$Q" | jq -r ".$1"; }
  CONN=$(n connections); MAXC=$(n max_connections)
  if [ "$CONN" -ge $((MAXC * 85 / 100)) ]; then fail "connections $CONN of $MAXC (almost out: new requests will fail)"
  elif [ "$CONN" -ge $((MAXC * 60 / 100)) ]; then warn "connections $CONN of $MAXC (getting full)"
  else pass "connections $CONN of $MAXC"; fi
  # (Realtime's own long-lived replication connection is not a client query and is left out above)
  [ "$(n longest_query_s)" -gt 30 ] && warn "a query has been running for $(n longest_query_s)s" || pass "longest running query $(n longest_query_s)s, $(n active) active"
  [ "$(n waiting_on_locks)" -gt 0 ] && warn "$(n waiting_on_locks) sessions waiting on locks" || pass "no sessions waiting on locks"
  [ "$(n minutes_since_start)" -lt 15 ] && warn "Postgres restarted $(n minutes_since_start) minutes ago" || pass "Postgres up for $(n minutes_since_start) minutes"
  if [ "$(n cron_failed_15m)" -gt 3 ]; then fail "$(n cron_failed_15m) background jobs failed in the last 15 minutes ($(n cron_ok_15m) ok)"
  elif [ "$(n cron_failed_15m)" -gt 0 ]; then warn "$(n cron_failed_15m) background job runs failed in the last 15 minutes ($(n cron_ok_15m) ok)"
  else pass "background jobs: $(n cron_ok_15m) ok, 0 failed in the last 15 minutes"; fi
  echo "        database size $(n db_size), $(n lives_now) lives right now, last viewer join $(n minutes_since_last_join) min ago"
fi

echo
echo "3. Migrations: repo vs production"
ML=$(supabase migration list --linked 2>/dev/null)
if [ -z "$ML" ]; then
  warn "could not read the migration list"
else
  # lines look like:   Local | Remote | Time ;  blank on one side means the other side only
  PENDING=$(echo "$ML" | awk -F'|' 'NF>=3 && $1 ~ /[0-9]/ && $2 !~ /[0-9]/ {gsub(/ /,"",$1); print $1}')
  REMOTE_ONLY=$(echo "$ML" | awk -F'|' 'NF>=3 && $1 !~ /[0-9]/ && $2 ~ /[0-9]/ {gsub(/ /,"",$2); print $2}')
  if [ -n "$PENDING" ]; then warn "in the repo but NOT in production (a push would apply them): $(echo $PENDING | tr '\n' ' ')"
  else pass "no pending migrations"; fi
  [ -n "$REMOTE_ONLY" ] && warn "in production but missing from the repo (applied by hand?): $(echo $REMOTE_ONLY | tr '\n' ' ')"
fi

echo
if [ "$FAILS" -gt 0 ]; then echo "RESULT: FAIL ($FAILS failed, $WARNS warnings)"; exit 1
elif [ "$WARNS" -gt 0 ]; then echo "RESULT: OK with $WARNS warning(s)"
else echo "RESULT: ALL GOOD"; fi
