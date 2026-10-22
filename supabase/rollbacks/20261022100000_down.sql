-- Down script for supabase/migrations/20261022100000_salary_admins_and_reward_diamonds.sql
-- Applied BY HAND only. Puts salary_report and salary_month_summary back to their previous columns (no agency code, admins or reward diamonds)
-- and drops salary_agency_map. The panel version that reads the new columns shows blanks for them after this; the old one is unaffected.
begin;
set local lock_timeout = '5s';
drop function if exists public.salary_month_summary(integer, uuid);
drop function if exists public.salary_report(text, uuid);
drop function if exists public.salary_agency_map();

create or replace function public.salary_report(p_month text, p_agency uuid default null)
returns table (
  host_id uuid,
  display_id bigint,
  host_name text,
  host_username text,
  agency_id uuid,
  agency_name text,
  period text,
  diamonds_earned bigint,
  live_hours numeric,
  live_days integer,
  withdrawn_diamonds bigint,
  available_diamonds bigint,
  slab_id uuid,
  slab_name text,
  payment_usd numeric,
  payslip_id uuid,
  payslip_status text,
  blocked_reason text
)
language plpgsql stable security definer set search_path = public
as $$
#variable_conflict use_column
declare
  v_from timestamptz;
  v_to timestamptz;
  v_period text;
begin
  if public.current_staff_role() is null then
    raise exception 'Staff only';
  end if;
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Pick a month as YYYY-MM';
  end if;
  v_from := (p_month || '-01')::date::timestamp at time zone 'Asia/Kolkata';
  v_to := ((p_month || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata';
  v_period := to_char((p_month || '-01')::date, 'Mon YYYY');

  return query
  with hosts as (
    select h.profile_id as pid, h.agency_id as ag, h.status as hstatus
      from public.host_profiles h
      join public.profiles p on p.id = h.profile_id
     where not coalesce(p.is_ghost, false)
       and (p_agency is null or h.agency_id = p_agency)
       and public.manages_agency(h.agency_id)
  ), earned as (
    select l.profile_id as pid, sum(l.amount)::bigint as d
      from public.wallet_ledger l
     where l.kind = 'gift_received' and l.currency = 'diamonds'
       and l.created_at >= v_from and l.created_at < v_to
       and l.profile_id in (select pid from hosts)
     group by 1
  ), per_day as (
    select s.host_id as pid, (s.started_at at time zone 'Asia/Kolkata')::date as d,
           sum(greatest(0, extract(epoch from (least(coalesce(s.ended_at, now()), s.last_heartbeat_at) - s.started_at)) / 60)) as mins
      from public.live_streams s
     where s.started_at >= v_from and s.started_at < v_to
       and s.host_id in (select pid from hosts)
     group by 1, 2
  ), live_tot as (
    select pd.pid, round(sum(pd.mins) / 60.0, 1) as hrs, (count(*) filter (where pd.mins >= 60))::int as days
      from per_day pd group by 1
  ), wd as (
    select w.profile_id as pid, sum(w.diamonds)::bigint as d
      from public.withdrawals w
     where w.status in ('pending', 'processing', 'paid')
       and w.requested_at >= v_from and w.requested_at < v_to
       and w.profile_id in (select pid from hosts)
     group by 1
  ), base as (
    select hs.pid, hs.ag, hs.hstatus,
           coalesce(e.d, 0) as earned, coalesce(lt.hrs, 0) as hrs, coalesce(lt.days, 0) as days,
           coalesce(x.d, 0) as wd, coalesce(wl.diamonds, 0)::bigint as avail
      from hosts hs
      left join earned e on e.pid = hs.pid
      left join live_tot lt on lt.pid = hs.pid
      left join wd x on x.pid = hs.pid
      left join public.wallets wl on wl.profile_id = hs.pid
  )
  select b.pid, p.display_id, p.name, p.username, b.ag, a.name, v_period,
         b.earned, b.hrs, b.days, b.wd, b.avail,
         sl.id, sl.name, sl.payment_usd,
         sp.id, sp.status,
         case
           when b.hstatus <> 'active' then 'Host is ' || b.hstatus
           when exists (select 1 from public.user_bans ub
                         where ub.user_id = b.pid and ub.kind = 'account' and ub.lifted_at is null
                           and (ub.ends_at is null or ub.ends_at > now())) then 'Account is banned'
         end
    from base b
    join public.profiles p on p.id = b.pid
    left join public.agencies a on a.id = b.ag
    left join lateral (
      select s.id, s.name, s.payment_usd from public.salary_slabs s
       where s.active and s.min_diamonds <= b.earned and s.min_live_hours <= b.hrs and s.min_live_days <= b.days
       order by s.payment_usd desc, s.min_diamonds desc limit 1) sl on true
    left join public.salary_payments sp on sp.payee_id = b.pid and sp.period = v_period
   where b.earned > 0 or b.hrs > 0 or sp.id is not null
   order by b.earned desc, p.name
   limit 2000;
end;
$$;
revoke execute on function public.salary_report(text, uuid) from public, anon;
grant execute on function public.salary_report(text, uuid) to authenticated;

create or replace function public.salary_month_summary(p_months integer default 12, p_agency uuid default null)
returns table (
  month text,
  period text,
  month_ended boolean,
  hosts_earning integer,
  diamonds_earned bigint,
  hosts_with_slab integer,
  payment_total numeric,
  payslips integer,
  payslips_usd numeric,
  paid_usd numeric
)
language plpgsql stable security definer set search_path = public
as $$
#variable_conflict use_column
declare
  v_n integer := least(greatest(coalesce(p_months, 12), 1), 24);
  v_cur date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
  v_d date;
  i integer;
begin
  if public.current_staff_role() is null then
    raise exception 'Staff only';
  end if;
  for i in 0 .. v_n - 1 loop
    v_d := (v_cur - make_interval(months => i))::date;
    return query
    select to_char(v_d, 'YYYY-MM'), to_char(v_d, 'Mon YYYY'), (i > 0),
           (count(*) filter (where r.diamonds_earned > 0))::int,
           coalesce(sum(r.diamonds_earned), 0)::bigint,
           (count(*) filter (where r.slab_id is not null and r.blocked_reason is null))::int,
           coalesce(sum(r.payment_usd) filter (where r.slab_id is not null and r.blocked_reason is null), 0)::numeric,
           (count(r.payslip_id))::int,
           coalesce(sum(sp.net_amount), 0)::numeric,
           coalesce(sum(sp.net_amount) filter (where sp.status = 'paid'), 0)::numeric
      from public.salary_report(to_char(v_d, 'YYYY-MM'), p_agency) r
      left join public.salary_payments sp on sp.id = r.payslip_id;
  end loop;
end;
$$;
revoke execute on function public.salary_month_summary(integer, uuid) from public, anon;
grant execute on function public.salary_month_summary(integer, uuid) to authenticated;

commit;
