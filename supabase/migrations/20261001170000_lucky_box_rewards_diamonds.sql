-- Lucky Box reward switches from coins to diamonds, per request.
alter table public.lucky_box_config rename column reward_coins to reward_diamonds;

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
    and started_at <= now() - (v_duration || ' minutes')::interval
    and not exists (
      select 1 from public.wallet_ledger
      where reference_table = 'live_streams'
        and reference_id = live_streams.id
        and note = 'lucky_box'
    );
end;
$$;

-- notify_wallet_ledger_entry() already interpolates new.currency into the
-- "Lucky Box! You earned X <currency>" message, so it needs no change.
