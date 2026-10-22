-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/salary_admins_test.sql
-- Proves (20261022100000): salary_agency_map gives each agency its public code and its Sub Admin and Country Admin with their app user IDs (the Global Admin
-- stays empty until a global_admin_id exists on the Country Admin row, and fills in once it does); salary_report carries them, plus the Lucky Box reward
-- diamonds of the month NET of pull-backs next to the gift diamonds; the month summary adds the reward diamonds; an agency manager only sees their own
-- agency; a non-staff caller is refused.
insert into auth.users (id, email) values
  ('b1000000-0000-0000-0000-000000000001', 'master@x'),
  ('b2000000-0000-0000-0000-000000000002', 'mgrA@x'),
  ('c1000000-0000-0000-0000-000000000001', 'hostA1@x'),
  ('c2000000-0000-0000-0000-000000000002', 'hostB1@x'),
  ('e1000000-0000-0000-0000-000000000001', 'sub@x'),
  ('e2000000-0000-0000-0000-000000000002', 'country@x'),
  ('e3000000-0000-0000-0000-000000000003', 'global@x'),
  ('d1000000-0000-0000-0000-000000000001', 'plain@x');
update public.profiles set name = 'Sub Admin X' where id = 'e1000000-0000-0000-0000-000000000001';
update public.profiles set name = 'Country Admin Y' where id = 'e2000000-0000-0000-0000-000000000002';
update public.profiles set name = 'Global Admin Z' where id = 'e3000000-0000-0000-0000-000000000003';
insert into public.agencies (id, name, sub_admin_id) values
  ('a0000000-0000-0000-0000-00000000000a', 'Agency A', 'e1000000-0000-0000-0000-000000000001'),
  ('a0000000-0000-0000-0000-00000000000b', 'Agency B', null);
insert into public.staff_roles (user_id, role, agency_id, country_admin_id) values
  ('b1000000-0000-0000-0000-000000000001', 'admin', null, null),
  ('b2000000-0000-0000-0000-000000000002', 'agency_manager', 'a0000000-0000-0000-0000-00000000000a', null),
  ('e1000000-0000-0000-0000-000000000001', 'sub_admin', 'a0000000-0000-0000-0000-00000000000a', 'e2000000-0000-0000-0000-000000000002'),
  ('e2000000-0000-0000-0000-000000000002', 'country_admin', null, null),
  ('e3000000-0000-0000-0000-000000000003', 'global_admin', null, null);
insert into public.host_profiles (profile_id, agency_id, status) values
  ('c1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000a', 'active'),
  ('c2000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-00000000000b', 'active');

-- Sep 2026 (IST): host A1 earns 5000 from gifts and gets three Lucky Box rewards (3000 each), one of them pulled back, one outside the month;
-- host B1 earns 1000 from gifts and no reward
insert into public.wallet_ledger (id, profile_id, kind, currency, amount, reference_table, reference_id, note, created_at) values
  ('f0000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'gift_received', 'diamonds', 5000, null, null, 'gift', timestamptz '2026-09-10 12:00+05:30'),
  ('f0000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'gift_received', 'diamonds', 1000, null, null, 'gift', timestamptz '2026-09-10 12:00+05:30'),
  ('f1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'grant', 'diamonds', 3000, 'live_streams', 'f2000000-0000-0000-0000-000000000001', 'lucky_box', timestamptz '2026-09-11 12:00+05:30'),
  ('f1000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', 'grant', 'diamonds', 3000, 'live_streams', 'f2000000-0000-0000-0000-000000000002', 'lucky_box', timestamptz '2026-09-12 12:00+05:30'),
  ('f1000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000001', 'grant', 'diamonds', 3000, 'live_streams', 'f2000000-0000-0000-0000-000000000003', 'lucky_box', timestamptz '2026-10-02 12:00+05:30');
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
  values ('c1000000-0000-0000-0000-000000000001', 'grant_reversal', 'diamonds', -3000, 'wallet_ledger', 'f1000000-0000-0000-0000-000000000002', 'Pulled back: Lucky Box reward', timestamptz '2026-09-13 12:00+05:30');

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000001', false);
select '1 a normal user is refused (expect t, t)' as check,
       pg_temp.refused('select * from public.salary_agency_map()', 'Staff only%') as map,
       pg_temp.refused('select * from public.salary_report(''2026-09'')', 'Staff only%') as report;

select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);
-- 2. the map for a Master
select '2 Agency A: its public code, Sub Admin X and Country Admin Y with their app IDs; no Global Admin yet (expect t, Sub Admin X, t, Country Admin Y, t, null)' as check,
       (select agency_code = (select display_id from public.agencies where id = 'a0000000-0000-0000-0000-00000000000a') from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000a') as code_ok,
       (select sub_admin_name from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000a') as sub,
       (select sub_admin_display_id = (select display_id from public.profiles where id = 'e1000000-0000-0000-0000-000000000001') from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000a') as sub_id_ok,
       (select country_admin_name from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000a') as country,
       (select country_admin_display_id = (select display_id from public.profiles where id = 'e2000000-0000-0000-0000-000000000002') from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000a') as country_id_ok,
       (select global_admin_name from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000a') as global;
select '2b Agency B has no Sub Admin: all admin columns empty (expect null, null, null)' as check,
       (select sub_admin_name from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000b') as sub,
       (select country_admin_name from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000b') as country,
       (select global_admin_name from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000b') as global;

-- 3. the report: gifts and rewards side by side, rewards net of the pull-back, only inside the month
select '3 host A1: 5000 from gifts, 3000 from rewards (the pulled-back and the October one are not counted), Agency A admins on the row (expect 5000, 3000, Sub Admin X, Country Admin Y)' as check,
       diamonds_earned, diamonds_rewards, sub_admin_name, country_admin_name
  from public.salary_report('2026-09') where host_id = 'c1000000-0000-0000-0000-000000000001';
select '3b host A1 carries the agency code (expect t)' as check,
       agency_code = (select display_id from public.agencies where id = 'a0000000-0000-0000-0000-00000000000a') as ok
  from public.salary_report('2026-09') where host_id = 'c1000000-0000-0000-0000-000000000001';
select '3c host B1: 1000 from gifts, 0 rewards, no admins (expect 1000, 0, null)' as check, diamonds_earned, diamonds_rewards, sub_admin_name
  from public.salary_report('2026-09') where host_id = 'c2000000-0000-0000-0000-000000000002';
select '3d a host with ONLY rewards still appears (expect 1 row, 0 gifts, 3000 rewards)' as check, count(*) as n, max(diamonds_earned) as gifts, max(diamonds_rewards) as rewards
  from public.salary_report('2026-10') where host_id = 'c1000000-0000-0000-0000-000000000001';

-- 4. the month summary
select '4 summary Sep 2026: 6000 gift diamonds and 3000 reward diamonds across the two hosts (expect 6000, 3000)' as check, diamonds_earned, diamonds_rewards
  from public.salary_month_summary(24) where month = '2026-09';

-- 5. an agency manager only sees their agency
select set_config('request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000002', false);
select '5 the agency manager map has only Agency A (expect 1, t)' as check, count(*) as n, bool_and(agency_id = 'a0000000-0000-0000-0000-00000000000a') as only_a from public.salary_agency_map();
select '5b the agency manager report has only host A1 (expect 1)' as check, count(*) as n from public.salary_report('2026-09');

-- 6. once the Country Admin row has a global_admin_id the Global Admin fills in (the field does not exist in production yet)
select set_config('request.jwt.claim.sub', '', false);
alter table public.staff_roles add column global_admin_id uuid;
update public.staff_roles set global_admin_id = 'e3000000-0000-0000-0000-000000000003' where user_id = 'e2000000-0000-0000-0000-000000000002';
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);
select '6 with the field in place Agency A shows Global Admin Z and the report row carries it (expect Global Admin Z, t)' as check,
       (select global_admin_name from public.salary_agency_map() where agency_id = 'a0000000-0000-0000-0000-00000000000a') as map,
       (select global_admin_display_id = (select display_id from public.profiles where id = 'e3000000-0000-0000-0000-000000000003') from public.salary_report('2026-09') where host_id = 'c1000000-0000-0000-0000-000000000001') as report;

-- 7. grants
select '7 anon cannot run the map, signed-in users can (expect f, t)' as check,
       has_function_privilege('anon', 'public.salary_agency_map()', 'execute') as anon,
       has_function_privilege('authenticated', 'public.salary_agency_map()', 'execute') as authed;
select set_config('request.jwt.claim.sub', '', false);
