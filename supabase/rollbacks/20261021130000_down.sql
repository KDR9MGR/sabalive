-- Down script for supabase/migrations/20261021130000_salary_payment_usd.sql
-- Applied BY HAND only, AFTER the 20261021140000 down script (the month summary depends on salary_report). Puts back the "reward / inr" names.
-- Cannot be undone by this script: audit-log rows written as 'salary.assign_payments'.
begin;
set local lock_timeout = '5s';
drop function if exists public.salary_assign_payments(text, uuid);
drop function if exists public.salary_report(text, uuid);
alter table public.salary_slabs rename column payment_usd to reward_inr;

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
  reward_inr numeric,
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
         sl.id, sl.name, sl.reward_inr,
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
      select s.id, s.name, s.reward_inr from public.salary_slabs s
       where s.active and s.min_diamonds <= b.earned and s.min_live_hours <= b.hrs and s.min_live_days <= b.days
       order by s.reward_inr desc, s.min_diamonds desc limit 1) sl on true
    left join public.salary_payments sp on sp.payee_id = b.pid and sp.period = v_period
   where b.earned > 0 or b.hrs > 0 or sp.id is not null
   order by b.earned desc, p.name
   limit 2000;
end;
$$;
revoke execute on function public.salary_report(text, uuid) from public, anon;
grant execute on function public.salary_report(text, uuid) to authenticated;

create or replace function public.salary_assign_rewards(p_month text, p_agency uuid default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
declare
  r record;
  v_period text;
  v_assigned integer := 0;
  v_total numeric := 0;
  v_existing integer := 0;
  v_blocked integer := 0;
begin
  if public.current_staff_role() is null then
    raise exception 'Staff only';
  end if;
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Pick a month as YYYY-MM';
  end if;
  -- only a month that is over: paying on half a month's earnings would be wrong
  if ((p_month || '-01')::date + interval '1 month')::date > (now() at time zone 'Asia/Kolkata')::date then
    raise exception '% has not ended yet — salary can only be assigned once the month is over', to_char((p_month || '-01')::date, 'FMMonth YYYY');
  end if;
  if not exists (select 1 from public.salary_slabs where active) then
    raise exception 'No salary slabs are set up yet — a Master adds them under Salary slabs first';
  end if;
  v_period := to_char((p_month || '-01')::date, 'Mon YYYY');

  for r in select * from public.salary_report(p_month, p_agency) where slab_id is not null loop
    if r.payslip_id is not null then v_existing := v_existing + 1; continue; end if;
    if r.blocked_reason is not null then v_blocked := v_blocked + 1; continue; end if;
    insert into public.salary_payments (payee_id, role, agency_id, period, base_amount, status)
      values (r.host_id, 'host', r.agency_id, v_period, r.reward_inr, 'processing')
      on conflict (payee_id, period) do nothing;
    if found then
      v_assigned := v_assigned + 1;
      v_total := v_total + r.reward_inr;
    else
      v_existing := v_existing + 1;
    end if;
  end loop;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'salary.assign_rewards',
            v_period || coalesce(' / agency ' || p_agency::text, ' / all agencies in scope') || ': ' || v_assigned || ' payslips, ₹' || v_total
              || ', ' || v_existing || ' already had one, ' || v_blocked || ' blocked',
            'warning');

  return jsonb_build_object('period', v_period, 'assigned', v_assigned, 'total_inr', v_total,
                            'already_had_payslip', v_existing, 'blocked', v_blocked);
end;
$$;
revoke execute on function public.salary_assign_rewards(text, uuid) from public, anon;
grant execute on function public.salary_assign_rewards(text, uuid) to authenticated;

commit;
