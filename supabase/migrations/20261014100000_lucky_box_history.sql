-- Lucky Box: a per-live history (last 7 days, rolling) that says, for every live, whether its box opened and, if not, why.
--
-- Why: hosts report "I stayed live and got nothing". The reward rules live in grant_lucky_box_rewards() (video lives
-- only, one reward per live, one per host per cooldown), so the honest answer is per live. This read-only function
-- applies the same rules to the lives of the last 7 days and names the outcome:
--   paid             the box opened and was paid (reward_id / reward_diamonds set)
--   pulled_back      it was paid and a Master took it back
--   in_progress      the live is still going and has not reached the duration yet
--   too_short        the live ended before the duration (counted until the host's last heartbeat, not the clean-up)
--   audio_room       reached the duration, but audio rooms never earn the box (the rule since 20261003120000)
--   cooldown         reached the duration while the host was resting (paid within the cooldown before it)
--   eligible_unpaid  met every rule and still has no payout: the one to look at
-- The window is capped at 7 days on the server, so older lives drop off by themselves. Nothing is written.
-- A new function with a new name: nothing existing changes. Rollback: supabase/rollbacks/20261014100000_down.sql.
create or replace function public.lucky_box_history(p_days integer default 7)
returns table (
  stream_id uuid,
  host_id uuid,
  host_name text,
  host_username text,
  host_display_id bigint,
  mode text,
  status text,
  started_at timestamptz,
  ended_at timestamptz,
  live_minutes integer,
  reward_id uuid,
  reward_diamonds integer,
  pulled_back boolean,
  result text,
  rest_hours numeric
)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_days integer := least(greatest(coalesce(p_days, 7), 1), 7);
  v_dur integer;
  v_cool integer;
begin
  if not public.staff_can('manage_lucky_box') then
    raise exception 'Only a Master or Super Admin with Lucky Box access can see this';
  end if;
  select c.duration_minutes, c.cooldown_hours into v_dur, v_cool from public.lucky_box_config c where c.id;
  if v_dur is null then return; end if;

  return query
  with base as (
    select s.id, s.host_id, s.mode, s.status, s.started_at, s.ended_at,
           -- a live is only as long as its host was really sending: stop at the last heartbeat (+ the 90 s grace the clean-up allows)
           greatest(0, floor(extract(epoch from (
             least(coalesce(s.ended_at, now()), s.last_heartbeat_at + interval '90 seconds') - s.started_at)) / 60))::int as live_min
      from public.live_streams s
     where s.started_at > now() - make_interval(days => v_days)
  ), j as (
    select b.*,
           w.id as win_id, w.amount::int as win_amount,
           (w.id is not null and exists (
              select 1 from public.wallet_ledger x
               where x.reference_table = 'wallet_ledger' and x.reference_id = w.id and x.kind = 'grant_reversal')) as win_pulled,
           prev.prev_at
      from base b
      left join lateral (
        select l.id, l.amount from public.wallet_ledger l
         where l.reference_table = 'live_streams' and l.reference_id = b.id and l.note = 'lucky_box' limit 1) w on true
      left join lateral (
        -- the host's most recent OTHER payout inside the cooldown before this live's box would have opened
        select max(r.created_at) as prev_at from public.wallet_ledger r
         where r.profile_id = b.host_id and r.note = 'lucky_box' and r.reference_id is distinct from b.id
           and r.created_at >  b.started_at + make_interval(mins => v_dur) - make_interval(hours => v_cool)
           and r.created_at <= b.started_at + make_interval(mins => v_dur) + interval '90 seconds') prev on v_cool > 0
  )
  select j.id, j.host_id, p.name, p.username, p.display_id, j.mode, j.status, j.started_at, j.ended_at, j.live_min,
         j.win_id, j.win_amount, j.win_pulled,
         case
           when j.win_id is not null then case when j.win_pulled then 'pulled_back' else 'paid' end
           when j.live_min < v_dur then case when j.status = 'live' then 'in_progress' else 'too_short' end
           when j.mode = 'audio' then 'audio_room'
           when j.prev_at is not null then 'cooldown'
           else 'eligible_unpaid'
         end,
         case when j.prev_at is not null then round(extract(epoch from (j.started_at + make_interval(mins => v_dur) - j.prev_at)) / 3600.0, 1) end
    from j
    join public.profiles p on p.id = j.host_id
   order by j.started_at desc
   limit 3000;
end;
$$;
revoke execute on function public.lucky_box_history(integer) from public, anon;
grant execute on function public.lucky_box_history(integer) to authenticated;
