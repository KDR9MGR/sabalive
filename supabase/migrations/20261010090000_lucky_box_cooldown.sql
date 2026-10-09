-- Lucky Box: at most one reward per host per cooldown (default 24 hours).
--
-- Why: the reward is paid once per unbroken live. A host whose phone dropped for a couple of minutes (the stale-live
-- clean-up closes the live) and who then went live again was paid a second time for what was, to them, one long
-- broadcast (host 100490: lives 16:17 and 17:01, rewards 16:58 and 17:42). Now a host who was paid in the last
-- `cooldown_hours` is not paid again.
--
-- The rule looks at the moment the box WOULD open (live start + duration): if the host was paid within the cooldown
-- before that moment, this live earns nothing, for good. A live that reaches the duration while the host is resting
-- is not paid hours later when the cooldown happens to end; the next box needs a new live. Pulled-back rewards still
-- count as paid (the original row stays), so pulling back does not reopen the box.
--
-- cooldown_hours = 0 turns the cooldown off. The panel edits it next to the duration and the reward.
--
-- Additive: a column with a default, a new function, and a replaced function body (same name, same no-argument
-- signature). Apps already installed keep working: they read duration_minutes and reward_diamonds by name; the box
-- they show for a host who is resting says "Opening..." and never pays, which is what the server decides.
alter table public.lucky_box_config
  add column if not exists cooldown_hours integer not null default 24
  check (cooldown_hours >= 0 and cooldown_hours <= 720);

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
  where s.status = 'live'
    and s.mode <> 'audio'
    and s.started_at <= now() - (v_duration || ' minutes')::interval
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
  order by s.host_id, s.started_at;
end;
$$;

-- What the app needs to show a truthful box for ANY live: when it opens, whether it was already paid, and until when
-- the host is resting (null = not resting). Nothing about amounts or wallets is returned, so a viewer can call it.
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
