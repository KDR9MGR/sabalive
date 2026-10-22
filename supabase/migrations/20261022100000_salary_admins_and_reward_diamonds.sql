-- Salary: who each agency sits under, the agency code, and the diamonds split into gifts and rewards.
--
--   salary_agency_map()   one row per agency in the caller's scope: the public Agency ID ("agency code", agencies.display_id) and, from the agency
--                         up, its Sub Admin (agencies.sub_admin_id), that Sub Admin's Country Admin (staff_roles.country_admin_id) and the Country
--                         Admin's Global Admin, each with their app-facing user ID (profiles.display_id), never the database id. The Global Admin
--                         is read from staff_roles.global_admin_id of the Country Admin row IF that field exists; today it does not (the panel's
--                         "Transfer Global" expects it but no migration ever created it), so the Global columns are empty until it does. Reading
--                         it through to_jsonb() keeps this function working both before and after such a field is added.
--   salary_report()       now also returns agency_code, the three admins (name + app ID) and diamonds_rewards: the Lucky Box payouts the host got in
--                         the month, NET of pull-backs. diamonds_earned stays the GIFT diamonds (the slab basis), so the two sources show side by side.
--   salary_month_summary  gets diamonds_rewards too (the month's reward diamonds across the hosts in scope).
-- Only columns are added to the two report functions (same names, same arguments, same meaning for every old column), so the panel that is live
-- today keeps working. They have to be dropped and recreated because Postgres cannot add output columns in place; both were created days ago and
-- only the admin panel calls them. Rollback: supabase/rollbacks/20261022100000_down.sql.
set local lock_timeout = '5s';

create or replace function public.salary_agency_map()
returns table (
  agency_id uuid,
  agency_code bigint,
  agency_name text,
  sub_admin_name text,
  sub_admin_display_id bigint,
  country_admin_name text,
  country_admin_display_id bigint,
  global_admin_name text,
  global_admin_display_id bigint
)
language plpgsql stable security definer set search_path = public
as $$
#variable_conflict use_column
begin
  if public.current_staff_role() is null then
    raise exception 'Staff only';
  end if;
  return query
  select a.id, a.display_id, a.name,
         sp.name, sp.display_id,
         cp.name, cp.display_id,
         gp.name, gp.display_id
    from public.agencies a
    left join public.profiles sp on sp.id = a.sub_admin_id
    left join public.staff_roles ssr on ssr.user_id = a.sub_admin_id
    left join public.profiles cp on cp.id = ssr.country_admin_id
    left join public.staff_roles csr on csr.user_id = ssr.country_admin_id
    left join public.profiles gp on gp.id = nullif(to_jsonb(csr) ->> 'global_admin_id', '')::uuid
   where public.manages_agency(a.id)
   order by a.display_id;
end;
$$;
revoke execute on function public.salary_agency_map() from public, anon;
grant execute on function public.salary_agency_map() to authenticated;

drop function if exists public.salary_report(text, uuid);
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
  blocked_reason text,
  agency_code bigint,
  sub_admin_name text,
  sub_admin_display_id bigint,
  country_admin_name text,
  country_admin_display_id bigint,
  global_admin_name text,
  global_admin_display_id bigint,
  diamonds_rewards bigint
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
  ), rewards as (
    -- Lucky Box payouts of the month, a pulled-back one left out (so this is the net the host really kept)
    select l.profile_id as pid, sum(l.amount)::bigint as d
      from public.wallet_ledger l
     where l.note = 'lucky_box' and l.kind = 'grant' and l.currency = 'diamonds'
       and l.created_at >= v_from and l.created_at < v_to
       and l.profile_id in (select pid from hosts)
       and not exists (select 1 from public.wallet_ledger x
                        where x.reference_table = 'wallet_ledger' and x.reference_id = l.id and x.kind = 'grant_reversal')
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
           coalesce(e.d, 0) as earned, coalesce(rw.d, 0) as rewards, coalesce(lt.hrs, 0) as hrs, coalesce(lt.days, 0) as days,
           coalesce(x.d, 0) as wd, coalesce(wl.diamonds, 0)::bigint as avail
      from hosts hs
      left join earned e on e.pid = hs.pid
      left join rewards rw on rw.pid = hs.pid
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
         end,
         m.agency_code, m.sub_admin_name, m.sub_admin_display_id, m.country_admin_name, m.country_admin_display_id,
         m.global_admin_name, m.global_admin_display_id,
         b.rewards
    from base b
    join public.profiles p on p.id = b.pid
    left join public.agencies a on a.id = b.ag
    left join public.salary_agency_map() m on m.agency_id = b.ag
    left join lateral (
      select s.id, s.name, s.payment_usd from public.salary_slabs s
       where s.active and s.min_diamonds <= b.earned and s.min_live_hours <= b.hrs and s.min_live_days <= b.days
       order by s.payment_usd desc, s.min_diamonds desc limit 1) sl on true
    left join public.salary_payments sp on sp.payee_id = b.pid and sp.period = v_period
   where b.earned > 0 or b.rewards > 0 or b.hrs > 0 or sp.id is not null
   order by b.earned desc, p.name
   limit 2000;
end;
$$;
revoke execute on function public.salary_report(text, uuid) from public, anon;
grant execute on function public.salary_report(text, uuid) to authenticated;

drop function if exists public.salary_month_summary(integer, uuid);
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
  paid_usd numeric,
  diamonds_rewards bigint
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
           coalesce(sum(sp.net_amount) filter (where sp.status = 'paid'), 0)::numeric,
           coalesce(sum(r.diamonds_rewards), 0)::bigint
      from public.salary_report(to_char(v_d, 'YYYY-MM'), p_agency) r
      left join public.salary_payments sp on sp.id = r.payslip_id;
  end loop;
end;
$$;
revoke execute on function public.salary_month_summary(integer, uuid) from public, anon;
grant execute on function public.salary_month_summary(integer, uuid) to authenticated;
