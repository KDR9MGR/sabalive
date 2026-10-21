-- Down script for supabase/migrations/20261021150000_lucky_box_ist_day_cooldown.sql
-- Applied BY HAND only. Puts the four functions back to their previous bodies (the rolling-hours cooldown), then drops the helpers and the column.
-- Hosts paid under the IST-day rule keep what they were paid; nothing is reversed. After this, cooldown_hours (23) is the rule again.
begin;
set local lock_timeout = '5s';

create or replace function public.grant_lucky_box_rewards()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_duration integer;
  v_reward integer;
  v_cooldown integer;
begin
  select duration_minutes, reward_diamonds, cooldown_hours into v_duration, v_reward, v_cooldown
  from public.lucky_box_config where id;
  if v_duration is null then return; end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
  select distinct on (s.host_id) s.host_id, 'grant', 'diamonds', v_reward, 'live_streams', s.id, 'lucky_box'
  from public.live_streams s
  where s.mode <> 'audio'
    and (
      -- still live: as before
      (s.status = 'live' and s.started_at <= now() - (v_duration || ' minutes')::interval)
      -- catch-up: ended in the last 30 minutes, and the host's own heartbeat proves the full duration
      or (s.status = 'ended'
          and s.ended_at > now() - interval '30 minutes'
          and s.last_heartbeat_at >= s.started_at + (v_duration || ' minutes')::interval)
    )
    and not exists (
      select 1 from public.wallet_ledger l
      where l.reference_table = 'live_streams'
        and l.reference_id = s.id
        and l.note = 'lucky_box'
    )
    and (
      v_cooldown = 0
      or not exists (
        select 1 from public.wallet_ledger r
        where r.profile_id = s.host_id
          and r.note = 'lucky_box'
          and r.created_at > s.started_at + (v_duration || ' minutes')::interval - make_interval(hours => v_cooldown)
      )
    )
  order by s.host_id, s.started_at
  on conflict (reference_id) where (note = 'lucky_box') do nothing;
end;
$$;

create or replace function public.lucky_box_pay_now(p_stream_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_s public.live_streams;
  v_dur integer;
  v_reward integer;
  v_cool integer;
  v_signal_min integer;
  v_box_at timestamptz;
  v_prev timestamptz;
begin
  if not (public.is_admin_or_above() and public.staff_cap_on('manage_lucky_box')) then
    raise exception 'Only a Master or Super Admin with Lucky Box access can pay a Lucky Box';
  end if;
  select duration_minutes, reward_diamonds, cooldown_hours into v_dur, v_reward, v_cool
    from public.lucky_box_config where id;
  if v_dur is null then raise exception 'Lucky Box is not set up'; end if;

  -- lock the live so two Masters pressing the button cannot both pay it
  select * into v_s from public.live_streams where id = p_stream_id for update;
  if v_s.id is null then raise exception 'That live does not exist'; end if;
  if v_s.started_at < now() - interval '7 days' then
    raise exception 'Only lives from the last 7 days can be paid';
  end if;
  if v_s.mode = 'audio' then raise exception 'Audio rooms never earn the Lucky Box'; end if;
  if exists (select 1 from public.wallet_ledger l
              where l.reference_table = 'live_streams' and l.reference_id = v_s.id and l.note = 'lucky_box') then
    raise exception 'This live was already paid';
  end if;

  -- the host's own signal must prove the full duration
  v_signal_min := greatest(0, floor(extract(epoch from (least(coalesce(v_s.ended_at, now()), v_s.last_heartbeat_at) - v_s.started_at)) / 60))::int;
  if v_signal_min < v_dur then
    raise exception 'This live only had % minutes of signal; the box needs %', v_signal_min, v_dur;
  end if;

  -- the same cooldown rule as the automatic payout
  v_box_at := v_s.started_at + make_interval(mins => v_dur);
  if v_cool > 0 then
    select max(r.created_at) into v_prev from public.wallet_ledger r
     where r.profile_id = v_s.host_id and r.note = 'lucky_box' and r.reference_id is distinct from v_s.id
       and r.created_at > v_box_at - make_interval(hours => v_cool)
       and r.created_at <= v_box_at + interval '90 seconds';
    if v_prev is not null then
      raise exception 'The host was paid at % — inside the % hour cooldown', to_char(v_prev, 'DD Mon HH24:MI'), v_cool;
    end if;
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
  values (v_s.host_id, 'grant', 'diamonds', v_reward, 'live_streams', v_s.id, 'lucky_box');

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'lucky_box.pay_now', v_s.id::text || ' -> ' || v_s.host_id::text || ' (' || v_reward || ')', 'warning');

  return jsonb_build_object('host_id', v_s.host_id, 'diamonds', v_reward, 'stream_id', v_s.id);
end;
$$;
revoke execute on function public.lucky_box_pay_now(uuid) from public, anon;
grant execute on function public.lucky_box_pay_now(uuid) to authenticated;

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
           -- a live is only as long as its host was really sending: stop at the last heartbeat
           greatest(0, floor(extract(epoch from (
             least(coalesce(s.ended_at, now()), s.last_heartbeat_at) - s.started_at)) / 60))::int as live_min
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

create or replace function public.lucky_box_status(p_stream_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_host uuid;
  v_started timestamptz;
  v_duration integer;
  v_cooldown integer;
  v_due timestamptz;
  v_last timestamptz;
  v_rest_until timestamptz;
begin
  select host_id, started_at into v_host, v_started from public.live_streams where id = p_stream_id;
  if v_host is null then return null; end if;
  select duration_minutes, cooldown_hours into v_duration, v_cooldown from public.lucky_box_config where id;
  if v_duration is null then return null; end if;

  v_due := v_started + (v_duration || ' minutes')::interval;
  select max(created_at) into v_last from public.wallet_ledger
   where profile_id = v_host and note = 'lucky_box' and reference_id is distinct from p_stream_id;
  v_rest_until := case when v_cooldown > 0 and v_last is not null then v_last + make_interval(hours => v_cooldown) end;

  return jsonb_build_object(
    'opens_at', v_due,
    'paid', exists (select 1 from public.wallet_ledger
                     where reference_table = 'live_streams' and reference_id = p_stream_id and note = 'lucky_box'),
    -- resting only if the last reward is close enough before the moment this box would open
    'rest_until', case when v_rest_until > v_due then v_rest_until end
  );
end;
$$;

revoke execute on function public.lucky_box_status(uuid) from public, anon;
grant execute on function public.lucky_box_status(uuid) to authenticated;

drop function if exists public.lucky_box_day_taken(uuid, uuid, timestamptz, integer);
drop function if exists public.lucky_box_day(timestamptz);
alter table public.lucky_box_config drop column if exists cooldown_mode;
commit;
