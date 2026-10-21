-- Salary: a month-by-month summary (Salary -> Monthly report -> "By month").
--
-- salary_month_summary(months, agency) returns ONE row per IST month, newest first (the current month, then back; at most 24 months), built from
-- salary_report() so the numbers are exactly the per-host report's, with the same scope (each role sees only its own agencies):
--   hosts_earning      hosts that received gift diamonds in the month
--   diamonds_earned    their gift diamonds in total
--   hosts_with_slab    hosts that reached a slab and are not blocked (banned / not active)
--   payment_total       what those hosts' slab payments add up to in USD (the payments "Assign Salary Payment" would create, or already created)
--   payslips           payslips that exist for the month (assigned by the button or typed by hand)
--   payslips_usd       their net pay in USD, and paid_usd the part already marked paid
--   month_ended        false for the current month (still a live preview, cannot be assigned yet)
-- Read-only. A new function with a new name: nothing existing changes. Needs 20261021130000 (salary_report returns payment_usd). Rollback: supabase/rollbacks/20261021140000_down.sql.
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
