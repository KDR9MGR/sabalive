-- Down script for supabase/migrations/20261026130000_diamond_reset_auto.sql
-- Applied BY HAND only, when that migration has to be undone. Run it BEFORE supabase/rollbacks/20261026120000_down.sql if both are to go.
--
-- Stops the automatic reset (the daily job, the switch and its settings) and puts the manual button back as 20261026120000 defined it. Cannot be undone by this script:
-- anything an automatic run already took (use the panel's Undo for that first; the runs stay in diamond_reset_runs, only their 'auto' marker column goes).
begin;
set local lock_timeout = '5s';

do $$
begin
  perform cron.unschedule('diamond-reset-auto');
exception when others then null;
end $$;
drop function if exists public.run_diamond_reset_auto(timestamptz);
drop function if exists public.admin_set_diamond_reset_auto(boolean, boolean, boolean, integer);

-- the manual button as it was in 20261026120000
create or replace function public.admin_reset_diamonds(p_period text, p_source text, p_confirm text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_to timestamptz;
  v_sources text[];
  s text;
  v_run uuid;
  w integer;
  d bigint;
  v_out jsonb := '[]'::jsonb;
  v_label text;
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

  -- one reset at a time, so two admins cannot both take the same month
  perform pg_advisory_xact_lock(hashtext('diamond_reset'));
  foreach s in array v_sources loop
    if exists (select 1 from public.diamond_reset_runs r where r.period = p_period and r.source = s and r.undone_at is null) then
      raise exception '% diamonds for % were already reset. Undo that run first if it must be redone.', case s when 'gift' then 'Gifting' else 'Reward' end, p_period;
    end if;
  end loop;

  foreach s in array v_sources loop
    v_label := case s when 'gift' then 'gifting' else 'reward' end;
    -- lock the wallets (in a fixed order) so the amounts cannot go stale while the rows are written; wallets.diamonds can never go below 0
    perform 1 from public.wallets wl
      where wl.profile_id in (select pl.profile_id from public._diamond_reset_plan(p_period, s) pl)
      order by wl.profile_id for update;
    insert into public.diamond_reset_runs (period, source, run_by) values (p_period, s, auth.uid()) returning id into v_run;
    with ins as (
      insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
        select pl.profile_id, 'grant_reversal', 'diamonds', -pl.amount, 'diamond_reset_runs', v_run,
               'Diamond reset ' || p_period || ' (' || v_label || ' diamonds)'
          from public._diamond_reset_plan(p_period, s) pl
        returning amount
    )
    select count(*), coalesce(-sum(amount), 0) into w, d from ins;
    update public.diamond_reset_runs set wallets = w, diamonds = d where id = v_run;
    insert into public.audit_logs (actor_id, action, target, severity)
      values (auth.uid(), 'diamonds.reset', p_period || ' ' || v_label || ': ' || d || ' diamonds from ' || w || ' wallets (run ' || v_run || ')', 'critical');
    v_out := v_out || jsonb_build_array(jsonb_build_object('source', s, 'run_id', v_run, 'wallets', w, 'diamonds', d));
  end loop;
  return v_out;
end;
$$;
revoke execute on function public.admin_reset_diamonds(text, text, text) from public, anon;
grant execute on function public.admin_reset_diamonds(text, text, text) to authenticated;

drop function if exists public._diamond_reset_run_one(text, text, uuid, boolean);
drop table if exists public.diamond_reset_settings;
alter table public.diamond_reset_runs drop column if exists auto;

commit;
