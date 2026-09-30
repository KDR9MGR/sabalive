-- Lucky Box: a host who stays live for a configured stretch (default 40
-- continuous minutes) in ONE stream gets a one-time coin reward (default
-- 3,000). "Continuous" is enforced for free by the existing
-- end_stale_live_streams cron (20260916090000): a real interruption long
-- enough to matter already ends the stream within ~90-150s, which starts a
-- fresh live_streams row (new started_at) on the next stream — so basing
-- the check on started_at for the CURRENT still-live row is already a
-- strict "must be one unbroken session" rule, no separate gap-tracking
-- needed. Per Rey (2026-09-29): one-time per stream, not repeating.
--
-- duration_minutes/reward_coins live in a singleton config row (not
-- constants) specifically so the admin panel can retune them without a
-- code deploy — same reasoning as level_thresholds/coin_packages being
-- catalog tables.
create table public.lucky_box_config (
  id boolean primary key default true,
  duration_minutes integer not null default 40 check (duration_minutes > 0),
  reward_coins integer not null default 3000 check (reward_coins > 0),
  updated_at timestamptz not null default now(),
  check (id)
);

insert into public.lucky_box_config (duration_minutes, reward_coins) values (40, 3000);

alter table public.lucky_box_config enable row level security;

create policy "Lucky box config is public" on public.lucky_box_config for select using (true);
create policy "Admins manage lucky box config"
  on public.lucky_box_config for update
  using (public.is_admin_or_above())
  with check (public.is_admin_or_above());

create function public.grant_lucky_box_rewards()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_duration integer;
  v_reward integer;
begin
  select duration_minutes, reward_coins into v_duration, v_reward
  from public.lucky_box_config where id;
  if v_duration is null then return; end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
  select host_id, 'grant', 'coins', v_reward, 'live_streams', id, 'lucky_box'
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

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'grant-lucky-box-rewards') then
    perform cron.schedule(
      'grant-lucky-box-rewards',
      '* * * * *',
      $sql$select public.grant_lucky_box_rewards()$sql$
    );
  end if;
end;
$outer$;

-- Give the "You received coins" push a nicer, specific message for this
-- reward specifically, instead of the generic grant wording — reuses the
-- notifications->push pipeline from 20260929100000 as-is, just a wording
-- special-case, so no double notification/push.
create or replace function public.notify_wallet_ledger_entry()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_body text;
begin
  v_body := case
    when new.kind = 'grant' and new.note = 'lucky_box' then
      'Lucky Box! You earned ' || new.amount || ' ' || new.currency || ' for a great streak of live time'
    when new.kind = 'gift_received' then 'You received a gift — +' || new.amount || ' ' || new.currency
    when new.kind = 'purchase' then 'Purchase successful — +' || new.amount || ' ' || new.currency
    when new.kind = 'grant' then 'You received ' || new.amount || ' ' || new.currency
    when new.kind = 'withdrawal' then 'Withdrawal of ' || abs(new.amount) || ' ' || new.currency || ' processed'
    else null
  end;
  if v_body is not null then
    insert into public.notifications (profile_id, kind, body)
    values (new.profile_id, case when new.note = 'lucky_box' then 'lucky_box' else 'coins_' || new.kind end, v_body);
  end if;
  return new;
end;
$$;
