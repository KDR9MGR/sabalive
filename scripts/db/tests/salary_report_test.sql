-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/salary_report_test.sql
-- Proves (20261021120000): the monthly report counts only gift diamonds in the IST month; a host gets the best slab they qualify for
-- (diamonds, live hours, live days); an agency manager sees only their own agency; blocked hosts are flagged; Assign Salary Reward
-- refuses an unfinished month and a month with no slabs, creates one processing payslip per qualifying host at the slab reward, never twice,
-- skips blocked hosts, and is audit-logged; only a Master can edit the slabs.
insert into auth.users (id, email) values
  ('b1000000-0000-0000-0000-000000000001', 'master@x'),
  ('b2000000-0000-0000-0000-000000000002', 'mgrA@x'),
  ('c1000000-0000-0000-0000-000000000001', 'host1@x'),
  ('c2000000-0000-0000-0000-000000000002', 'host2@x'),
  ('c3000000-0000-0000-0000-000000000003', 'host3@x'),
  ('c4000000-0000-0000-0000-000000000004', 'host4@x'),
  ('c5000000-0000-0000-0000-000000000005', 'host5@x'),
  ('c6000000-0000-0000-0000-000000000006', 'host6@x'),
  ('d1000000-0000-0000-0000-000000000001', 'plain@x');
insert into public.agencies (id, name) values
  ('a0000000-0000-0000-0000-00000000000a', 'Agency A'),
  ('a0000000-0000-0000-0000-00000000000b', 'Agency B');
insert into public.staff_roles (user_id, role, agency_id) values
  ('b1000000-0000-0000-0000-000000000001', 'admin', null),
  ('b2000000-0000-0000-0000-000000000002', 'agency_manager', 'a0000000-0000-0000-0000-00000000000a');
insert into public.host_profiles (profile_id, agency_id, status) values
  ('c1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000a', 'active'),   -- big earner, lots of live time
  ('c2000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-00000000000a', 'active'),   -- earns enough diamonds but too little live time for the top slab
  ('c3000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-00000000000a', 'suspended'),-- blocked
  ('c4000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-00000000000b', 'active'),   -- other agency
  ('c5000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-00000000000a', 'active'),   -- banned
  ('c6000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-00000000000a', 'active');   -- earns below every slab
insert into public.user_bans (user_id, kind, reason) values ('c5000000-0000-0000-0000-000000000005', 'account', 'test');

-- gift diamonds: Sep 2026 (IST) counts, the edges and other months and kinds do not
create or replace function pg_temp.gift(p_host text, p_amount bigint, p_at text, p_kind text default 'gift_received') returns void language sql as $$
  insert into public.wallet_ledger (profile_id, kind, currency, amount, note, created_at)
  values (('c' || p_host || '000000-0000-0000-0000-00000000000' || p_host)::uuid, p_kind, 'diamonds', p_amount, 'test', (p_at || '+05:30')::timestamptz);
$$;
select pg_temp.gift('1', 400000, '2026-09-10 12:00'); select pg_temp.gift('1', 200000, '2026-09-30 23:59');      -- 600000 in Sep
select pg_temp.gift('1', 999999, '2026-10-01 00:00');                                                        -- Oct: not Sep
select pg_temp.gift('1', 50000, '2026-09-15 10:00', 'grant');                                                  -- a grant is not an earning
select pg_temp.gift('2', 150000, '2026-09-05 12:00');
select pg_temp.gift('3', 700000, '2026-09-05 12:00');
select pg_temp.gift('4', 800000, '2026-09-05 12:00');
select pg_temp.gift('5', 700000, '2026-09-05 12:00');
select pg_temp.gift('6', 900, '2026-09-05 12:00');

-- live time in Sep: host1 = 12 days x 90 min; host2 = 2 days x 90 min
insert into public.live_streams (host_id, title, status, mode, started_at, ended_at, last_heartbeat_at)
select 'c1000000-0000-0000-0000-000000000001', 'l', 'ended', 'video', ts, ts + interval '90 minutes', ts + interval '90 minutes'
  from generate_series(timestamptz '2026-09-02 10:00+05:30', timestamptz '2026-09-13 10:00+05:30', interval '1 day') ts;
insert into public.live_streams (host_id, title, status, mode, started_at, ended_at, last_heartbeat_at)
select 'c2000000-0000-0000-0000-000000000002', 'l', 'ended', 'video', ts, ts + interval '90 minutes', ts + interval '90 minutes'
  from generate_series(timestamptz '2026-09-02 10:00+05:30', timestamptz '2026-09-03 10:00+05:30', interval '1 day') ts;

-- a withdrawal in Sep for host1, and the wallet balance (the ledger inserts above already credited diamonds)
insert into public.withdrawals (profile_id, diamonds, status, requested_at) values ('c1000000-0000-0000-0000-000000000001', 10000, 'paid', timestamptz '2026-09-20 10:00+05:30');

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

-- 1. a normal user cannot use the report
select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000001', false);
select '1 a normal user cannot see the report (expect t)' as check, pg_temp.refused('select * from public.salary_report(''2026-09'')', 'Staff only%') as ok;

-- 2. slabs (row-level security applies: run as the signed-in role, not the superuser)
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);
select '2 no slabs yet: assigning is refused (expect t)' as check, pg_temp.refused('select public.salary_assign_rewards(''2026-09'')', 'No salary slabs are set up yet%') as ok;
set role authenticated;
insert into public.salary_slabs (name, min_diamonds, min_live_hours, min_live_days, reward_inr) values
  ('Bronze', 100000, 0, 0, 2000),
  ('Silver', 500000, 0, 0, 10000),
  ('Gold', 500000, 10, 10, 25000),     -- needs the live time as well
  ('Retired', 1, 0, 0, 99999);
update public.salary_slabs set active = false where name = 'Retired';
select '2b a Master added 4 slabs (expect 4)' as check, count(*) as n from public.salary_slabs;
select set_config('request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000002', false);
select '2c an agency manager can read the slabs (expect 4)' as check, count(*) as n from public.salary_slabs;
select '2d an agency manager cannot add a slab (expect t)' as check,
       pg_temp.refused('insert into public.salary_slabs (name, min_diamonds, reward_inr) values (''x'', 1000, 100)', '%row-level security%') as ok;
update public.salary_slabs set reward_inr = 1;
delete from public.salary_slabs;
reset role;
select '2e an agency manager cannot change or delete a slab (expect 0 changed, 4 left)' as check,
       (select count(*) from public.salary_slabs where reward_inr = 1) as changed, (select count(*) from public.salary_slabs) as left_n;
set role authenticated;
select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000001', false);
select '2f a normal user sees no slabs (expect 0)' as check, count(*) as n from public.salary_slabs;
reset role;

-- 3. the report for a Master (everyone)
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);
select '3 host1: 600000 earned (the Oct, grant and edge rows do not count), 18 live hours, 12 days, Gold 25000 (expect 600000, 18.0, 12, Gold, 25000)' as check,
       diamonds_earned, live_hours, live_days, slab_name, reward_inr
  from public.salary_report('2026-09') where host_name is not null and host_id = 'c1000000-0000-0000-0000-000000000001';
select '3b host1 withdrew 10000 in the month (expect 10000)' as check, withdrawn_diamonds as n from public.salary_report('2026-09') where host_id = 'c1000000-0000-0000-0000-000000000001';
select '3c host2 has 150000 but little live time: Bronze 2000 (expect 150000, Bronze, 2000)' as check, diamonds_earned, slab_name, reward_inr
  from public.salary_report('2026-09') where host_id = 'c2000000-0000-0000-0000-000000000002';
select '3d host3 (suspended) and host5 (banned) are flagged (expect Host is suspended, Account is banned)' as check,
       (select blocked_reason from public.salary_report('2026-09') where host_id = 'c3000000-0000-0000-0000-000000000003') as host3,
       (select blocked_reason from public.salary_report('2026-09') where host_id = 'c5000000-0000-0000-0000-000000000005') as host5;
select '3e host6 earned below every slab: no slab (expect null)' as check, slab_id as n from public.salary_report('2026-09') where host_id = 'c6000000-0000-0000-0000-000000000006';
select '3f the agency filter narrows (expect 1 host in B)' as check, count(*) as n from public.salary_report('2026-09', 'a0000000-0000-0000-0000-00000000000b');

-- 4. scope: an agency manager only sees Agency A
select set_config('request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000002', false);
select '4 the agency manager sees A hosts only (expect 5 rows, none from B)' as check, count(*) as n,
       bool_and(agency_id = 'a0000000-0000-0000-0000-00000000000a') as only_a from public.salary_report('2026-09');
select '4b asking for agency B returns nothing (expect 0)' as check, count(*) as n from public.salary_report('2026-09', 'a0000000-0000-0000-0000-00000000000b');

-- 5. assigning
select '5 an unfinished month is refused (expect t)' as check, pg_temp.refused('select public.salary_assign_rewards(''2099-01'')', '% has not ended yet%') as ok;
select '5b a bad month is refused (expect t)' as check, pg_temp.refused('select public.salary_assign_rewards(''Sep'')', 'Pick a month as YYYY-MM%') as ok;
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);
create temp table a1 as select public.salary_assign_rewards('2026-09') as j;
select '5c assigned: host1 25000 + host2 2000 + host4 10000 = 3 payslips, 37000; host3 and host5 blocked; host6 has no slab (expect 3, 37000, 0, 2)' as check,
       (j ->> 'assigned')::int as assigned, (j ->> 'total_inr')::numeric as total, (j ->> 'already_had_payslip')::int as existing, (j ->> 'blocked')::int as blocked from a1;
select '5d payslips are processing host payslips for Sep 2026 with the slab reward as base (expect 3, t, 25000)' as check,
       count(*) as n, bool_and(status = 'processing' and role = 'host' and period = 'Sep 2026') as ok,
       (select base_amount from public.salary_payments where payee_id = 'c1000000-0000-0000-0000-000000000001') as host1_base
  from public.salary_payments;
select '5e a second run adds nothing (expect 0, 3)' as check,
       (public.salary_assign_rewards('2026-09') ->> 'assigned')::int as assigned,
       (select count(*) from public.salary_payments) as payslips;
select '5f the report now shows the payslip status (expect processing)' as check, payslip_status from public.salary_report('2026-09') where host_id = 'c1000000-0000-0000-0000-000000000001';
select '5g audited (expect 2 rows)' as check, count(*) as n from public.audit_logs where action = 'salary.assign_rewards';

-- 6. an agency manager can assign for their own agency only
delete from public.salary_payments;
select set_config('request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000002', false);
create temp table a6 as select public.salary_assign_rewards('2026-09') as j;
select '6 the agency manager assigning gets only Agency A hosts: host1 + host2 (expect 2, 27000, 0 from B)' as check,
       (j ->> 'assigned')::int as assigned,
       (select sum(base_amount) from public.salary_payments) as total,
       (select count(*) from public.salary_payments where agency_id = 'a0000000-0000-0000-0000-00000000000b') as from_b
  from a6;
select set_config('request.jwt.claim.sub', '', false);

-- 7. grants
select '7 anon cannot run either (expect f, f, t, t)' as check,
       has_function_privilege('anon', 'public.salary_report(text,uuid)', 'execute') as anon_report,
       has_function_privilege('anon', 'public.salary_assign_rewards(text,uuid)', 'execute') as anon_assign,
       has_function_privilege('authenticated', 'public.salary_report(text,uuid)', 'execute') as authed_report,
       has_function_privilege('authenticated', 'public.salary_assign_rewards(text,uuid)', 'execute') as authed_assign;
