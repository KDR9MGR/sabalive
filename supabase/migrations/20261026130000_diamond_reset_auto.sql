-- Diamond reset, part 2: the AUTOMATIC monthly reset (a toggle, a "gifting" and a "reward" checkbox, and the day of the month), run by a daily job.
--
-- Builds on 20261026120000_diamond_reset (the manual buttons). Nothing runs by itself until a Master / Super Admin switches it ON in the panel (Economy -> Diamond Reset);
-- the switch starts OFF.
--   diamond_reset_settings      ONE row: enabled (default off), reset_gift / reset_reward (the checkboxes, both ticked by default), run_day (1-28, default 1), and what the
--                               last automatic run did (last_auto_at / last_auto_note, shown in the panel).
--   admin_set_diamond_reset_auto(enabled, gift, reward, day)   Master / Super Admin only; refuses "on" with no box ticked; a critical-ish audit row.
--   run_diamond_reset_auto([now])   the job. Every day at 00:05 India time (18:35 UTC) pg_cron calls it. It does nothing unless the switch is on AND today (India time) is the
--                               chosen day; then it resets the PREVIOUS month for each ticked kind that has not been reset yet (a month that was already reset by hand is left alone).
--                               One kind failing never undoes the other: each runs in its own sub-transaction, a failure is written to the audit log and to last_auto_note.
--                               Only runs for a month that has ended. Not callable by app users or anon.
--   _diamond_reset_run_one(month, kind, actor, auto)   the single place where one kind of one month is taken off the wallets. The manual button (admin_reset_diamonds, replaced
--                               below with the same checks and messages) and the job both call it, so they cannot drift apart. Runs made by the job have run_by = NULL and auto = true.
-- The amounts, the once-per-month rule, the ledger rows and Undo are exactly those of the manual buttons (see 20261026120000).
--
-- Additive: a column and a table, new functions, one job; admin_reset_diamonds (unapplied on production until this ships with it) is replaced.
-- Rollback: supabase/rollbacks/20261026130000_down.sql (put it back BEFORE rolling back 20261026120000).

alter table public.diamond_reset_runs add column if not exists auto boolean not null default false;

create table if not exists public.diamond_reset_settings (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  reset_gift boolean not null default true,
  reset_reward boolean not null default true,
  run_day integer not null default 1 check (run_day between 1 and 28),
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  last_auto_at timestamptz,
  last_auto_note text
);
insert into public.diamond_reset_settings (id) values (true) on conflict (id) do nothing;

alter table public.diamond_reset_settings enable row level security;
drop policy if exists "Staff read diamond reset settings" on public.diamond_reset_settings;
create policy "Staff read diamond reset settings" on public.diamond_reset_settings for select using (public.is_admin_or_above());
revoke insert, update, delete on public.diamond_reset_settings from anon, authenticated;

-- ---------------------------------------------------------------------------
-- the one place that resets one kind of one month
-- ---------------------------------------------------------------------------
create or replace function public._diamond_reset_run_one(p_period text, p_source text, p_actor uuid, p_auto boolean)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_run uuid;
  w integer;
  d bigint;
  v_label text;
begin
  if p_source is null or p_source not in ('gift', 'reward') then
    raise exception 'Choose gifting diamonds or reward diamonds';
  end if;
  v_label := case p_source when 'gift' then 'gifting' else 'reward' end;
  if exists (select 1 from public.diamond_reset_runs r where r.period = p_period and r.source = p_source and r.undone_at is null) then
    raise exception '% diamonds for % were already reset. Undo that run first if it must be redone.', case p_source when 'gift' then 'Gifting' else 'Reward' end, p_period;
  end if;
  -- lock the wallets (in a fixed order) so the amounts cannot go stale while the rows are written; wallets.diamonds can never go below 0
  perform 1 from public.wallets wl
    where wl.profile_id in (select pl.profile_id from public._diamond_reset_plan(p_period, p_source) pl)
    order by wl.profile_id for update;
  insert into public.diamond_reset_runs (period, source, run_by, auto) values (p_period, p_source, p_actor, coalesce(p_auto, false)) returning id into v_run;
  with ins as (
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
      select pl.profile_id, 'grant_reversal', 'diamonds', -pl.amount, 'diamond_reset_runs', v_run,
             'Diamond reset ' || p_period || ' (' || v_label || ' diamonds)'
        from public._diamond_reset_plan(p_period, p_source) pl
      returning amount
  )
  select count(*), coalesce(-sum(amount), 0) into w, d from ins;
  update public.diamond_reset_runs set wallets = w, diamonds = d where id = v_run;
  insert into public.audit_logs (actor_id, action, target, severity)
    values (p_actor, case when coalesce(p_auto, false) then 'diamonds.reset_auto' else 'diamonds.reset' end,
            p_period || ' ' || v_label || ': ' || d || ' diamonds from ' || w || ' wallets (run ' || v_run || ')', 'critical');
  return jsonb_build_object('source', p_source, 'run_id', v_run, 'wallets', w, 'diamonds', d);
end;
$$;
revoke execute on function public._diamond_reset_run_one(text, text, uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- the manual button: same checks and messages as before, now through the shared function
-- ---------------------------------------------------------------------------
create or replace function public.admin_reset_diamonds(p_period text, p_source text, p_confirm text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_to timestamptz;
  v_sources text[];
  s text;
  v_out jsonb := '[]'::jsonb;
begin
  if not public._diamond_reset_actor_ok() then
    raise exception 'Only a Master or Super Admin can reset diamonds';
  end if;
  if p_period is null or p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Pick a month as YYYY-MM';
  end if;
  if p_source is null or p_source not in ('gift', 'reward', 'both') then
    raise exception 'Choose gifting diamonds, reward diamonds or both';
  end if;
  v_to := ((p_period || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata';
  if v_to > now() then
    raise exception 'That month has not ended yet (India time). Reset a finished month.';
  end if;
  if btrim(coalesce(p_confirm, '')) <> p_period then
    raise exception 'Type the month (%) to confirm', p_period;
  end if;
  v_sources := case p_source when 'both' then array['gift', 'reward'] else array[p_source] end;

  -- one reset at a time (the automatic job takes the same lock), so two runs cannot both take the same month
  perform pg_advisory_xact_lock(hashtext('diamond_reset'));
  foreach s in array v_sources loop
    if exists (select 1 from public.diamond_reset_runs r where r.period = p_period and r.source = s and r.undone_at is null) then
      raise exception '% diamonds for % were already reset. Undo that run first if it must be redone.', case s when 'gift' then 'Gifting' else 'Reward' end, p_period;
    end if;
  end loop;
  foreach s in array v_sources loop
    v_out := v_out || jsonb_build_array(public._diamond_reset_run_one(p_period, s, auth.uid(), false));
  end loop;
  return v_out;
end;
$$;
revoke execute on function public.admin_reset_diamonds(text, text, text) from public, anon;
grant execute on function public.admin_reset_diamonds(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- the switch and the checkboxes
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_diamond_reset_auto(p_enabled boolean, p_gift boolean, p_reward boolean, p_day integer)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_on boolean := coalesce(p_enabled, false);
  v_gift boolean := coalesce(p_gift, false);
  v_reward boolean := coalesce(p_reward, false);
  v_row public.diamond_reset_settings%rowtype;
begin
  if not public._diamond_reset_actor_ok() then
    raise exception 'Only a Master or Super Admin can change the automatic diamond reset';
  end if;
  if p_day is null or p_day < 1 or p_day > 28 then
    raise exception 'Pick a day of the month from 1 to 28';
  end if;
  if v_on and not v_gift and not v_reward then
    raise exception 'Tick at least one: gifting diamonds or reward diamonds';
  end if;
  update public.diamond_reset_settings
     set enabled = v_on, reset_gift = v_gift, reset_reward = v_reward, run_day = p_day, updated_by = auth.uid(), updated_at = now()
   where id
   returning * into v_row;
  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'diamonds.reset_auto_settings',
            case when v_on then 'ON' else 'OFF' end || ': gifting ' || case when v_gift then 'yes' else 'no' end || ', reward ' || case when v_reward then 'yes' else 'no' end || ', day ' || p_day,
            case when v_on then 'critical' else 'warning' end);
  return to_jsonb(v_row);
end;
$$;
revoke execute on function public.admin_set_diamond_reset_auto(boolean, boolean, boolean, integer) from public, anon;
grant execute on function public.admin_set_diamond_reset_auto(boolean, boolean, boolean, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- the daily job
-- ---------------------------------------------------------------------------
create or replace function public.run_diamond_reset_auto(p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  cfg public.diamond_reset_settings%rowtype;
  v_ist timestamp := p_now at time zone 'Asia/Kolkata';
  v_period text;
  v_to timestamptz;
  s text;
  r jsonb;
  v_notes text[] := '{}';
begin
  select * into cfg from public.diamond_reset_settings where id;
  if not found or not cfg.enabled then
    return jsonb_build_object('ran', false, 'why', 'off');
  end if;
  if extract(day from v_ist)::int <> cfg.run_day then
    return jsonb_build_object('ran', false, 'why', 'not the day');
  end if;
  v_period := to_char(date_trunc('month', v_ist) - interval '1 month', 'YYYY-MM');
  v_to := date_trunc('month', v_ist) at time zone 'Asia/Kolkata';
  if v_to > now() then
    return jsonb_build_object('ran', false, 'why', 'month not ended');
  end if;

  perform pg_advisory_xact_lock(hashtext('diamond_reset'));
  foreach s in array array['gift', 'reward'] loop
    if (s = 'gift' and not cfg.reset_gift) or (s = 'reward' and not cfg.reset_reward) then
      continue;
    end if;
    if exists (select 1 from public.diamond_reset_runs x where x.period = v_period and x.source = s and x.undone_at is null) then
      v_notes := v_notes || (s || ': already reset');
      continue;
    end if;
    begin
      r := public._diamond_reset_run_one(v_period, s, null, true);
      v_notes := v_notes || (s || ': ' || (r ->> 'diamonds') || ' diamonds from ' || (r ->> 'wallets') || ' wallets');
    exception when others then
      v_notes := v_notes || (s || ' FAILED: ' || left(sqlerrm, 200));
      insert into public.audit_logs (actor_id, action, target, severity)
        values (null, 'diamonds.reset_auto_failed', v_period || ' ' || s || ': ' || left(sqlerrm, 200), 'critical');
    end;
  end loop;
  update public.diamond_reset_settings
     set last_auto_at = now(), last_auto_note = v_period || ' - ' || array_to_string(v_notes, '; ')
   where id;
  return jsonb_build_object('ran', true, 'period', v_period, 'notes', to_jsonb(v_notes));
end;
$$;
revoke execute on function public.run_diamond_reset_auto(timestamptz) from public, anon, authenticated;

-- 00:05 India time every day (18:35 UTC); the function itself decides whether today is the day
do $$
begin
  perform cron.unschedule('diamond-reset-auto');
exception when others then null;
end $$;
select cron.schedule('diamond-reset-auto', '35 18 * * *', $cron$ select public.run_diamond_reset_auto() $cron$);
