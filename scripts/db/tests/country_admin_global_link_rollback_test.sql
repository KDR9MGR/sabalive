-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/country_admin_global_link_rollback_test.sql
-- Proves supabase/rollbacks/20261026100000_down.sql: the column, the trigger and both functions are gone, creating a staff audit row still works, salary_agency_map()
-- keeps working (the Global Admin columns go back to empty), a second run is harmless, and the migration applies again.
insert into auth.users (id, email) values
  ('b1000000-0000-0000-0000-0000000000b2', 'master@x'), ('c1000000-0000-0000-0000-0000000000c3', 'global@x'),
  ('d1000000-0000-0000-0000-0000000000d5', 'country@x'), ('e1000000-0000-0000-0000-0000000000e8', 'sub@x');
insert into public.staff_roles (user_id, role) values ('b1000000-0000-0000-0000-0000000000b2', 'admin'), ('c1000000-0000-0000-0000-0000000000c3', 'global_admin'), ('d1000000-0000-0000-0000-0000000000d5', 'country_admin');
insert into public.staff_roles (user_id, role, country_admin_id) values ('e1000000-0000-0000-0000-0000000000e8', 'sub_admin', 'd1000000-0000-0000-0000-0000000000d5');
insert into public.agencies (name, sub_admin_id) values ('Rollback agency', 'e1000000-0000-0000-0000-0000000000e8');
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-0000000000b2', false);
select public.transfer_country_admin('d1000000-0000-0000-0000-0000000000d5', 'c1000000-0000-0000-0000-0000000000c3');
select '1 before: the chain has a Global Admin (expect t)' as check, global_admin_name is not null as ok from public.salary_agency_map() where agency_name = 'Rollback agency';

\i supabase/rollbacks/20261026100000_down.sql

select '2 the column, the trigger and the functions are gone (expect 0, 0, 0)' as check,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'staff_roles' and column_name = 'global_admin_id') as col,
       (select count(*) from pg_trigger where tgname = 'audit_logs_link_country_admin') as trg,
       (select count(*) from pg_proc where proname in ('transfer_country_admin', 'link_new_country_admin_to_global')) as fns;
insert into public.audit_logs (actor_id, action, target, severity) values ('c1000000-0000-0000-0000-0000000000c3', 'staff.created', 'd1000000-0000-0000-0000-0000000000d5 -> country_admin', 'warning');
select '3 a staff audit row still goes in (expect 1)' as check, count(*) as n from public.audit_logs where action = 'staff.created';
select '4 the salary map still works, the Global Admin is empty again (expect t, t)' as check, sub_admin_name is not null as sub_ok, global_admin_name is null as global_empty
  from public.salary_agency_map() where agency_name = 'Rollback agency';

\i supabase/rollbacks/20261026100000_down.sql
select '5 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'transfer_country_admin';

\i supabase/migrations/20261026100000_country_admin_global_link.sql
select '6 re-applied: the audit row above links the Country Admin by the back-fill (expect c1)' as check, left(global_admin_id::text, 2) as g from public.staff_roles where user_id = 'd1000000-0000-0000-0000-0000000000d5';
