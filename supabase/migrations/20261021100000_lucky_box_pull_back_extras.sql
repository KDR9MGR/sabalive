-- Lucky Box: take back the EXTRA boxes a host got on the same day (Lucky Box page -> "Extra boxes in one day").
--
-- Why: while the cooldown was left at 0, hosts collected several boxes a day. The owner's rule for the clean-up: ONE box per host
-- per calendar day (IST) is fine; every further box on that day is pulled back, the first of the day stays.
--   lucky_box_extra_wins(from, to)         preview: every unreversed win that is not the host's first of its day, with the host's balance
--   lucky_box_pull_back_extras(from, to)   does it: one 'grant_reversal' row per extra win (tied to the win, like lucky_box_pull_back, so
--                                          each can happen once), a per-win audit row and a critical summary row. A host who no longer
--                                          holds the diamonds is SKIPPED and listed in the answer; nothing is ever taken below zero.
-- Wins already pulled back are ignored, so running it twice finds nothing the second time. The days are whole IST days from `from` to `to`
-- inclusive, so a day is never cut in half. The window is capped at 40 days. Masters / Super Admins with Lucky Box access only.
-- New functions with new names: nothing the apps call changes. Rollback: supabase/rollbacks/20261021100000_down.sql.
create or replace function public.lucky_box_extra_wins(p_from date, p_to date, p_tz text default 'Asia/Kolkata')
returns table (
  ledger_id uuid,
  host_id uuid,
  host_name text,
  host_username text,
  host_display_id bigint,
  won_at timestamptz,
  win_day date,
  wins_that_day integer,
  diamonds bigint,
  stream_id uuid,
  host_balance bigint,
  can_cover boolean
)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
begin
  if not public.staff_can('manage_lucky_box') then
    raise exception 'Only a Master or Super Admin with Lucky Box access can see this';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Pick a start day and an end day (end on or after start)';
  end if;
  if p_to - p_from > 40 then
    raise exception 'Pick a window of at most 40 days';
  end if;
  v_from := p_from::timestamp at time zone p_tz;
  v_to := (p_to + 1)::timestamp at time zone p_tz;

  return query
  with wins as (
    select l.id, l.profile_id, l.amount, l.created_at, l.reference_id,
           (l.created_at at time zone p_tz)::date as d
      from public.wallet_ledger l
     where l.note = 'lucky_box' and l.kind = 'grant'
       and l.created_at >= v_from and l.created_at < v_to
       and not exists (
         select 1 from public.wallet_ledger x
          where x.reference_table = 'wallet_ledger' and x.reference_id = l.id and x.kind = 'grant_reversal')
  ), ranked as (
    select w.*, row_number() over (partition by w.profile_id, w.d order by w.created_at, w.id) as rn,
           count(*) over (partition by w.profile_id, w.d) as n
      from wins w
  )
  select r.id, r.profile_id, p.name, p.username, p.display_id, r.created_at, r.d, r.n::int, r.amount, r.reference_id,
         coalesce(wl.diamonds, 0), coalesce(wl.diamonds, 0) >= r.amount
    from ranked r
    join public.profiles p on p.id = r.profile_id
    left join public.wallets wl on wl.profile_id = r.profile_id
   where r.rn > 1
   order by r.profile_id, r.created_at;
end;
$$;
revoke execute on function public.lucky_box_extra_wins(date, date, text) from public, anon;
grant execute on function public.lucky_box_extra_wins(date, date, text) to authenticated;

create or replace function public.lucky_box_pull_back_extras(p_from date, p_to date, p_tz text default 'Asia/Kolkata')
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  v_win public.wallet_ledger;
  v_balance bigint;
  v_pulled integer := 0;
  v_diamonds bigint := 0;
  v_hosts uuid[] := '{}';
  v_skipped jsonb := '[]'::jsonb;
begin
  if not (public.is_admin_or_above() and public.staff_cap_on('manage_lucky_box')) then
    raise exception 'Only a Master or Super Admin with Lucky Box access can pull back Lucky Box rewards';
  end if;

  for r in select * from public.lucky_box_extra_wins(p_from, p_to, p_tz) order by host_id, won_at loop
    -- lock the win, then look again: another Master may have pulled it back a moment ago
    select * into v_win from public.wallet_ledger where id = r.ledger_id for update;
    if exists (select 1 from public.wallet_ledger x
                where x.reference_table = 'wallet_ledger' and x.reference_id = v_win.id and x.kind = 'grant_reversal') then
      continue;
    end if;

    select w.diamonds into v_balance from public.wallets w where w.profile_id = v_win.profile_id for update;
    if coalesce(v_balance, 0) < v_win.amount then
      v_skipped := v_skipped || jsonb_build_object('ledger_id', v_win.id, 'host_id', v_win.profile_id, 'host', r.host_name,
                                                    'diamonds', v_win.amount, 'balance', coalesce(v_balance, 0));
      continue;
    end if;

    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
      values (v_win.profile_id, 'grant_reversal', v_win.currency, -v_win.amount, 'wallet_ledger', v_win.id,
              'Pulled back: extra Lucky Box that day');
    insert into public.audit_logs (actor_id, action, target, severity)
      values (auth.uid(), 'lucky_box.pull_back', v_win.id::text, 'warning');

    v_pulled := v_pulled + 1;
    v_diamonds := v_diamonds + v_win.amount;
    if not (v_win.profile_id = any (v_hosts)) then v_hosts := v_hosts || v_win.profile_id; end if;
  end loop;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'lucky_box.pull_back_extras',
            p_from::text || '..' || p_to::text || ': ' || v_pulled || ' wins, ' || v_diamonds || ' diamonds, '
              || coalesce(array_length(v_hosts, 1), 0) || ' hosts, ' || jsonb_array_length(v_skipped) || ' skipped',
            'critical');

  return jsonb_build_object('pulled', v_pulled, 'diamonds', v_diamonds, 'hosts', coalesce(array_length(v_hosts, 1), 0), 'skipped', v_skipped);
end;
$$;
revoke execute on function public.lucky_box_pull_back_extras(date, date, text) from public, anon;
grant execute on function public.lucky_box_pull_back_extras(date, date, text) to authenticated;
