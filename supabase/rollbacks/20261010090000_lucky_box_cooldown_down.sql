-- Down script for supabase/migrations/20261010090000_lucky_box_cooldown.sql
-- Applied BY HAND only. Puts the payout function back to its previous body (20261003120000: video lives only, one
-- reward per live, no cooldown), removes the status function and the setting. Rewards already paid are untouched.
begin;
set local lock_timeout = '5s';

create or replace function public.grant_lucky_box_rewards()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_duration integer;
  v_reward integer;
begin
  select duration_minutes, reward_diamonds into v_duration, v_reward
  from public.lucky_box_config where id;
  if v_duration is null then return; end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
  select host_id, 'grant', 'diamonds', v_reward, 'live_streams', id, 'lucky_box'
  from public.live_streams
  where status = 'live'
    and mode <> 'audio'
    and started_at <= now() - (v_duration || ' minutes')::interval
    and not exists (
      select 1 from public.wallet_ledger
      where reference_table = 'live_streams'
        and reference_id = live_streams.id
        and note = 'lucky_box'
    );
end;
$$;

drop function if exists public.lucky_box_status(uuid);
alter table public.lucky_box_config drop column if exists cooldown_hours;
commit;
