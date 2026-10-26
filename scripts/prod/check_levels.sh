#!/usr/bin/env bash
# Are people's Wealth and Charm levels and XP what the panel's Levels page says they should be? READ-ONLY, and it prints only COUNTS (no names, no ids).
#
#   scripts/prod/check_levels.sh                                          # the linked project (production)
#   SUPABASE_WORKDIR=$HOME/.sabalive-staging-workdir scripts/prod/check_levels.sh   # staging
#
# For each track (wealth = coins spent, charm = coins received) it checks, against `track_levels` (what Master -> Levels edits):
#   1. the ladder itself: levels run 1..N without a gap and level 1 needs 0 XP;
#   2. LEVEL: everyone's stored level is the HIGHEST level whose XP they have reached (what the panel's save and the gift trigger both compute);
#   3. XP: everyone's stored XP equals the coins on their gifts (the trigger adds each gift's coins once). A difference is not always a fault (XP from before the
#      trigger existed, or a gift row removed later), so it is a WARN with the size of the biggest gap, not a FAIL.
# Exit 1 only on a FAIL (a wrong ladder or a wrong level).
set -uo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/supabase_login.sh
command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }
sb() { supabase ${SUPABASE_WORKDIR:+--workdir "$SUPABASE_WORKDIR"} "$@"; }
LINKED=$(cat "${SUPABASE_WORKDIR:-.}/supabase/.temp/project-ref" 2>/dev/null || echo unknown)
rows() { sb db query --linked -o json "$1" 2>/dev/null | jq -c 'if type=="array" then . else .rows end' 2>/dev/null; }

FAILS=0; WARNS=0
pass() { printf '  PASS  %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; WARNS=$((WARNS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

echo "Levels and XP check  ($(date -u +%Y-%m-%d\ %H:%M:%S) UTC)   project: $LINKED   (read-only, counts only)"

echo
echo "1. The ladders (Master -> Levels)"
LADDER=$(rows "select track, count(*)::int as levels, max(level)::int as top, count(*) filter (where level = 1 and xp_required <> 0)::int as bad_first from public.track_levels group by track order by track")
if [ -z "$LADDER" ] || [ "$LADDER" = "null" ] || [ "$LADDER" = "[]" ]; then fail "could not read track_levels"; else
  for t in wealth charm; do
    row=$(echo "$LADDER" | jq -c --arg t "$t" '.[] | select(.track == $t)')
    if [ -z "$row" ]; then fail "$t: no levels at all"; continue; fi
    n=$(echo "$row" | jq .levels); top=$(echo "$row" | jq .top); bad=$(echo "$row" | jq .bad_first)
    [ "$n" = "$top" ] && pass "$t: levels 1 to $top, no gaps" || fail "$t: $n levels but the top is $top (a gap)"
    [ "$bad" = "0" ] && pass "$t: level 1 needs 0 XP" || fail "$t: level 1 does not need 0 XP"
  done
fi

echo
echo "2. Everyone's level and XP against the ladder"
SQL="
with gifts_out as (select sender_id as id, sum(coins)::bigint as coins from public.gift_transactions group by sender_id),
     gifts_in as (select receiver_id as id, sum(coins)::bigint as coins from public.gift_transactions group by receiver_id),
w as (
  select p.wealth_xp::bigint as xp, p.wealth_level as lvl,
         coalesce((select max(t.level) from public.track_levels t where t.track = 'wealth' and t.xp_required <= p.wealth_xp), 1) as want,
         coalesce(g.coins, 0) as earned
  from public.profiles p left join gifts_out g on g.id = p.id),
c as (
  select p.charm_xp::bigint as xp, p.charm_level as lvl,
         coalesce((select max(t.level) from public.track_levels t where t.track = 'charm' and t.xp_required <= p.charm_xp), 1) as want,
         coalesce(g.coins, 0) as earned
  from public.profiles p left join gifts_in g on g.id = p.id)
select 'wealth' as track, count(*)::int as people, count(*) filter (where lvl <> want)::int as wrong_level,
       count(*) filter (where xp <> earned)::int as xp_differs, coalesce(max(abs(xp - earned)), 0)::bigint as biggest_gap from w
union all
select 'charm', count(*)::int, count(*) filter (where lvl <> want)::int, count(*) filter (where xp <> earned)::int, coalesce(max(abs(xp - earned)), 0)::bigint from c
order by 1 desc"
RES=$(rows "$SQL")
if [ -z "$RES" ] || [ "$RES" = "null" ] || [ "$RES" = "[]" ]; then fail "could not read the profiles"; else
  for t in wealth charm; do
    row=$(echo "$RES" | jq -c --arg t "$t" '.[] | select(.track == $t)')
    [ -n "$row" ] || { fail "$t: no answer"; continue; }
    people=$(echo "$row" | jq .people); wrong=$(echo "$row" | jq .wrong_level); diff=$(echo "$row" | jq .xp_differs); gap=$(echo "$row" | jq .biggest_gap)
    [ "$wrong" = "0" ] && pass "$t level: all $people people are at the level their XP reaches" || fail "$t level: $wrong of $people people are NOT at the level their XP reaches (the panel's save re-levels everyone, so this should be 0)"
    [ "$diff" = "0" ] && pass "$t XP: every person's XP equals the coins on their gifts" || warn "$t XP: $diff of $people people have XP different from their gift coins (biggest gap $gap): old XP from before the trigger, or a removed gift"
  done
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "RESULT: OK ($WARNS warning(s))"; else echo "RESULT: $FAILS FAILED"; exit 1; fi
