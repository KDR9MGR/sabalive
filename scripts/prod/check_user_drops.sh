#!/usr/bin/env bash
# Why might ONE person say they are dropped out of lives? READ-ONLY. Prints what the server knows about that account, and no email, phone, IP or device id.
#
#   scripts/prod/check_user_drops.sh 101081          # the User ID shown under the name in the app (profiles.display_id)
#
# It looks at the reasons the app or the server can end a viewer's live (see the list printed at the end): a ban, a host kick, the account signed in on a second
# phone (that signs the first one out, and shows the earlier phone the notice "signed in on another device"), a "log everyone out", very short watching times
# (a connection or phone problem), and the phone models used.
set -uo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/supabase_login.sh
command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }
ID="${1:-}"
[[ "$ID" =~ ^[0-9]{3,12}$ ]] || { echo "usage: $0 <User ID, digits only>"; exit 2; }
sb() { supabase ${SUPABASE_WORKDIR:+--workdir "$SUPABASE_WORKDIR"} "$@"; }
LINKED=$(cat "${SUPABASE_WORKDIR:-.}/supabase/.temp/project-ref" 2>/dev/null || echo unknown)
rows() { sb db query --linked -o json "$1" 2>/dev/null | jq -c 'if type=="array" then . else .rows end' 2>/dev/null; }
show() { echo "$1" | jq -r "$2" 2>/dev/null; }

echo "Drop-out check for User ID $ID  ($(date -u +%Y-%m-%d\ %H:%M:%S) UTC)   project: $LINKED   (read-only)"

P=$(rows "select id, created_at, status, coalesce(is_ghost,false) as ghost from public.profiles where display_id = $ID limit 1")
if [ -z "$P" ] || [ "$P" = "[]" ] || [ "$P" = "null" ]; then echo "  No account with User ID $ID (or the database could not be read)."; exit 1; fi
echo
echo "1. Account"
show "$P" '.[0] | "  created \(.created_at[0:16])   status: \(.status)   ghost: \(.ghost)"'

echo
echo "2. Bans (any kind, newest first)"
B=$(rows "select b.kind, b.starts_at, b.ends_at, b.lifted_at from public.user_bans b join public.profiles p on p.id = b.user_id where p.display_id = $ID order by b.created_at desc limit 8")
[ "$B" = "[]" ] && echo "  none" || show "$B" '.[] | "  \(.kind)  from \(.starts_at[0:16])  until \(.ends_at // "permanent" | .[0:16])  \(if .lifted_at then "LIFTED " + .lifted_at[0:16] else "not lifted" end)"'

echo
echo "3. Kicked by a host in the last day (older kicks are deleted by the server)"
K=$(rows "select count(*)::int as n from public.live_stream_kicks k join public.profiles p on p.id = k.user_id where p.display_id = $ID")
echo "  $(show "$K" '.[0].n') kick(s)"

echo
echo "4. Phones this account has used"
D=$(rows "select d.platform, d.model, d.first_seen_at, d.last_seen_at from public.user_devices d join public.profiles p on p.id = d.user_id where p.display_id = $ID order by d.last_seen_at desc limit 8")
[ "$D" = "[]" ] && echo "  none recorded" || show "$D" '.[] | "  \(.platform) \(.model)   first \(.first_seen_at[0:10])   last \(.last_seen_at[0:16])"'

echo
echo "5. The phone that holds the account's one active sign-in (a sign-in somewhere else signs this one out)"
S=$(rows "select s.platform, s.model, s.signed_in_at from public.user_active_session s join public.profiles p on p.id = s.user_id where p.display_id = $ID")
[ "$S" = "[]" ] && echo "  none" || show "$S" '.[0] | "  \(.platform) \(.model)   signed in \(.signed_in_at[0:16])"'

echo
echo "6. Last sign-ins (a sign-in on a DIFFERENT phone shortly before a complaint = the first phone was signed out)"
L=$(rows "select l.method, l.platform, l.model, l.created_at from public.user_login_events l join public.profiles p on p.id = l.user_id where p.display_id = $ID order by l.created_at desc limit 10")
[ "$L" = "[]" ] && echo "  none" || show "$L" '.[] | "  \(.created_at[0:16])  \(.method)  \(.platform) \(.model)"'

echo
echo "7. Watching time in the last 7 days. 'Server closed' = the server saw NO heartbeat for 75 s+ and closed the visit itself (the app sends one every 30 s)"
W=$(rows "select count(*)::int as joins, count(*) filter (where m < 1)::int as under_1, count(*) filter (where m >= 1 and m < 5)::int as one_to_5, count(*) filter (where m >= 5)::int as over_5, count(*) filter (where swept)::int as swept, count(*) filter (where v_left is null)::int as still_open from (select v.left_at as v_left, extract(epoch from (coalesce(v.left_at, now()) - v.joined_at)) / 60.0 as m, (v.left_at is not null and extract(epoch from (v.left_at - v.last_heartbeat_at)) >= 74) as swept from public.live_stream_viewers v join public.profiles p on p.id = v.viewer_id where p.display_id = $ID and v.joined_at > now() - interval '7 days') t")
show "$W" '.[0] | "  \(.joins) joins:  under 1 min \(.under_1),  1-5 min \(.one_to_5),  over 5 min \(.over_5),  still open \(.still_open)   |   server closed (no heartbeat): \(.swept)"'

echo
echo "8. Last 15 lives joined (seconds watched, host, and who ended the visit)"
J=$(rows "select v.joined_at, v.left_at, round(extract(epoch from (coalesce(v.left_at, now()) - v.joined_at)))::int as secs, round(extract(epoch from (v.left_at - v.last_heartbeat_at)))::int as silent_secs, left(s.id::text, 6) as live, h.display_id as host, s.status, (v.left_at is not null and s.ended_at is not null and abs(extract(epoch from (v.left_at - s.ended_at))) < 60) as live_ended_then from public.live_stream_viewers v join public.live_streams s on s.id = v.live_stream_id join public.profiles p on p.id = v.viewer_id left join public.profiles h on h.id = s.host_id where p.display_id = $ID order by v.joined_at desc limit 15")
[ "$J" = "[]" ] && echo "  none" || show "$J" '.[] | "  \(.joined_at[0:16])  \(.secs) s  live \(.live) host \(.host)   \(if .left_at == null then "still open" elif .live_ended_then then "the host ended it" elif .silent_secs >= 74 then "SERVER closed it (no heartbeat for \(.silent_secs) s)" else "left (the phone told the server)" end)"'

echo
echo "9. Everyone, same 7 days (for comparison; counts only)"
A=$(rows "select count(*)::int as joins, count(distinct viewer_id)::int as people, round(100.0 * count(*) filter (where m < 1) / nullif(count(*), 0))::int as pct_under_1, round(100.0 * count(*) filter (where swept) / nullif(count(*), 0))::int as pct_swept, round(count(*)::numeric / nullif(count(distinct viewer_id), 0) / 7, 1) as joins_per_person_day from (select v.viewer_id, extract(epoch from (coalesce(v.left_at, now()) - v.joined_at)) / 60.0 as m, (v.left_at is not null and extract(epoch from (v.left_at - v.last_heartbeat_at)) >= 74) as swept from public.live_stream_viewers v where v.joined_at > now() - interval '7 days') t")
show "$A" '.[0] | "  \(.joins) joins by \(.people) people (\(.joins_per_person_day) joins per person per day):  \(.pct_under_1)% under 1 min,  \(.pct_swept)% closed by the server"'

echo
echo "10. Lives this person joined MORE THAN ONCE in 7 days (a rejoin means they left or were dropped and came back)"
R=$(rows "select left(s.id::text, 6) as live, h.display_id as host, count(*)::int as joins, round((sum(extract(epoch from (coalesce(v.left_at, now()) - v.joined_at))) / 60.0)::numeric, 1) as minutes from public.live_stream_viewers v join public.live_streams s on s.id = v.live_stream_id join public.profiles p on p.id = v.viewer_id left join public.profiles h on h.id = s.host_id where p.display_id = $ID and v.joined_at > now() - interval '7 days' group by s.id, h.display_id having count(*) >= 2 order by max(v.joined_at) desc limit 10")
[ "$R" = "[]" ] && echo "  none" || show "$R" '.[] | "  live \(.live) host \(.host):  \(.joins) joins, \(.minutes) min in all"'

cat <<'EOF'

How to read it. Every way the app or server ends a viewer's live:
  - host kicked / banned the person ........ the screen says "The host removed you from this live" (section 3, and the host's own list)
  - account or live ban ..................... signs out / refuses the join (section 2)
  - the account signed in on a SECOND phone . the first phone is signed out and shown "signed in on another device" (sections 5 and 6)
  - Super Admin "log everyone out" .......... every phone signs out once (Release controls)
  - the live ended ........................... "the host ended it" in section 8
  - connection trouble ....................... the room's access token is renewed in the background every hour; if the phone has no network at that moment, or Agora refuses, it shows "Your connection to this room expired" / "Can't reach the live service"; shows as many joins UNDER 1 MINUTE in section 7
  - the phone itself ......................... power saving / battery rules on some makes (Realme, Oppo, Xiaomi, Vivo) freeze the app in the background
EOF
