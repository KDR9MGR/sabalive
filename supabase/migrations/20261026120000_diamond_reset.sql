-- Monthly diamond reset: a Master / Super Admin clears a finished month's GIFT diamonds, REWARD (Lucky Box) diamonds, or both, from the wallets that still hold them.
--
-- Why: wallets.diamonds is a running balance (gifts and Lucky Box payouts add to it, withdrawals take from it). The Salary reports already work out each month's
-- gift and reward diamonds from the ledger, so a month "starts from zero" there, but the balance never did. This is the button for it.
--
-- WHAT IT REMOVES, per wallet, for a month that has ended (India time, like the Salary reports) and one source:
--   gift   = the diamonds the wallet received as gifts that month ('gift_received' ledger rows),
--   reward = the diamonds it won in Lucky Box that month, a pulled-back win left out (the same figure as the Salary report's "Diamonds from rewards").
-- Never more than the wallet holds, and never diamonds that arrived AFTER the month: withdrawals are assumed to use the oldest diamonds first, so what is taken
-- is at most (balance now - positive diamond credits since the month ended; the credits of a reset's own Undo do not count). A wallet that already withdrew its month's diamonds therefore loses little or nothing.
-- Everything else stays (other months, other credits). Ghost accounts are skipped. Each (month, source) can be reset ONCE; "both" is gift + reward in one step.
--
-- HOW IT IS RECORDED: one negative 'grant_reversal' ledger row per wallet (an existing kind: no change to wallet_ledger_kind_check), tied to the run through
-- reference_table 'diamond_reset_runs' / reference_id = the run, so it is NOT counted as a gift or a reward by the Salary reports and is easy to trace. A run is one row
-- in diamond_reset_runs. Because it is an ordinary ledger row, each host gets the standard "N diamonds were reclaimed from your wallet by an admin" notification.
-- UNDO: admin_undo_diamond_reset(run) gives the exact diamonds back ('grant' rows) and frees the month for another run.
--
-- WHO: is_admin_or_above() (Master and Super Admin; a lower role can hold run_payroll but never passes) AND the run_payroll switch (on for them by default, an
-- explicit false blocks). Typed confirmation (the month) is checked HERE, not only in the panel. Every run is a critical audit-log row.
--
-- Functions: admin_diamond_reset_preview(month) (read only, what each button would take), admin_reset_diamonds(month, 'gift'|'reward'|'both', confirm),
-- admin_undo_diamond_reset(run, confirm). Internal: _diamond_reset_plan, _diamond_reset_actor_ok.
-- All NEW; nothing the apps call changes. Rollback: supabase/rollbacks/20261026120000_down.sql.

create table if not exists public.diamond_reset_runs (
  id uuid primary key default gen_random_uuid(),
  period text not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  source text not null check (source in ('gift', 'reward')),
  run_by uuid references public.profiles (id) on delete set null,
  run_at timestamptz not null default now(),
  wallets integer not null default 0,
  diamonds bigint not null default 0,
  undone_at timestamptz,
  undone_by uuid references public.profiles (id) on delete set null
);
-- one live run per month and source; an undone run frees the slot
create unique index if not exists diamond_reset_runs_once on public.diamond_reset_runs (period, source) where undone_at is null;

alter table public.diamond_reset_runs enable row level security;
drop policy if exists "Staff read diamond resets" on public.diamond_reset_runs;
create policy "Staff read diamond resets" on public.diamond_reset_runs for select using (public.is_admin_or_above());
revoke insert, update, delete on public.diamond_reset_runs from anon, authenticated;

-- ---------------------------------------------------------------------------
-- who may press the buttons
-- ---------------------------------------------------------------------------
create or replace function public._diamond_reset_actor_ok()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.is_admin_or_above() and public.staff_cap_on('run_payroll');
$$;
revoke execute on function public._diamond_reset_actor_ok() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- what a reset would take (the one definition both the preview and the run use)
-- ---------------------------------------------------------------------------
create or replace function public._diamond_reset_plan(p_period text, p_source text)
returns table (profile_id uuid, amount bigint)
language sql stable security definer set search_path = public
as $$
  with b as (
    select (p_period || '-01')::date::timestamp at time zone 'Asia/Kolkata' as t_from,
           ((p_period || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata' as t_to
  ), src as (
    select l.profile_id as pid, sum(l.amount)::bigint as d
      from public.wallet_ledger l, b
     where l.currency = 'diamonds' and l.created_at >= b.t_from and l.created_at < b.t_to
       and ((p_source = 'gift' and l.kind = 'gift_received')
         or (p_source = 'reward' and l.kind = 'grant' and l.note = 'lucky_box'
             and not exists (select 1 from public.wallet_ledger x
                              where x.reference_table = 'wallet_ledger' and x.reference_id = l.id and x.kind = 'grant_reversal')))
     group by l.profile_id
  ), later as (
    select l.profile_id as pid, sum(l.amount)::bigint as d
      from public.wallet_ledger l, b
     where l.currency = 'diamonds' and l.amount > 0 and l.created_at >= b.t_to
       and l.reference_table is distinct from 'diamond_reset_runs'   -- the diamonds an Undo gave back are not "new" diamonds
       and l.profile_id in (select pid from src)
     group by l.profile_id
  )
  select s.pid, least(s.d, greatest(0, w.diamonds - coalesce(la.d, 0)))::bigint
    from src s
    join public.wallets w on w.profile_id = s.pid
    join public.profiles p on p.id = s.pid and not coalesce(p.is_ghost, false)
    left join later la on la.pid = s.pid
   where s.d > 0 and w.diamonds > 0
     and least(s.d, greatest(0, w.diamonds - coalesce(la.d, 0))) > 0;
$$;
revoke execute on function public._diamond_reset_plan(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- preview (read only)
-- ---------------------------------------------------------------------------
create or replace function public.admin_diamond_reset_preview(p_period text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_to timestamptz;
  v_out jsonb := '{}'::jsonb;
  s text;
  w integer;
  d bigint;
  v_run public.diamond_reset_runs%rowtype;
begin
  if not public._diamond_reset_actor_ok() then
    raise exception 'Only a Master or Super Admin can reset diamonds';
  end if;
  if p_period is null or p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Pick a month as YYYY-MM';
  end if;
  v_to := ((p_period || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata';
  foreach s in array array['gift', 'reward'] loop
    select count(*), coalesce(sum(pl.amount), 0) into w, d from public._diamond_reset_plan(p_period, s) pl;
    select * into v_run from public.diamond_reset_runs r where r.period = p_period and r.source = s and r.undone_at is null;
    v_out := v_out || jsonb_build_object(s, jsonb_build_object(
      'wallets', w, 'diamonds', d,
      'done', v_run.id is not null, 'run_id', v_run.id, 'run_at', v_run.run_at, 'removed', v_run.diamonds, 'removed_wallets', v_run.wallets));
  end loop;
  return v_out || jsonb_build_object('period', p_period, 'ended', v_to <= now());
end;
$$;
revoke execute on function public.admin_diamond_reset_preview(text) from public, anon;
grant execute on function public.admin_diamond_reset_preview(text) to authenticated;

-- ---------------------------------------------------------------------------
-- the reset
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- undo a run: the exact diamonds go back, the month can be reset again
-- ---------------------------------------------------------------------------
create or replace function public.admin_undo_diamond_reset(p_run_id uuid, p_confirm text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_run public.diamond_reset_runs%rowtype;
  w integer;
  d bigint;
begin
  if not public._diamond_reset_actor_ok() then
    raise exception 'Only a Master or Super Admin can undo a diamond reset';
  end if;
  perform pg_advisory_xact_lock(hashtext('diamond_reset'));
  select * into v_run from public.diamond_reset_runs r where r.id = p_run_id for update;
  if not found then
    raise exception 'No such reset';
  end if;
  if v_run.undone_at is not null then
    raise exception 'That reset was already undone';
  end if;
  if btrim(coalesce(p_confirm, '')) <> v_run.period then
    raise exception 'Type the month (%) to confirm', v_run.period;
  end if;

  with back as (
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
      select l.profile_id, 'grant', 'diamonds', -l.amount, 'diamond_reset_runs', v_run.id,
             'Diamond reset ' || v_run.period || ' undone'
        from public.wallet_ledger l
       where l.reference_table = 'diamond_reset_runs' and l.reference_id = v_run.id and l.kind = 'grant_reversal' and l.currency = 'diamonds'
      returning amount
  )
  select count(*), coalesce(sum(amount), 0) into w, d from back;
  update public.diamond_reset_runs set undone_at = now(), undone_by = auth.uid() where id = v_run.id;
  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'diamonds.reset_undone', v_run.period || ' ' || v_run.source || ': ' || d || ' diamonds back to ' || w || ' wallets (run ' || v_run.id || ')', 'critical');
  return jsonb_build_object('run_id', v_run.id, 'wallets', w, 'diamonds', d);
end;
$$;
revoke execute on function public.admin_undo_diamond_reset(uuid, text) from public, anon;
grant execute on function public.admin_undo_diamond_reset(uuid, text) to authenticated;
