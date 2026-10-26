-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/diamond_reset_auto_rollback_test.sql
-- Proves supabase/rollbacks/20261026130000_down.sql: the automatic reset is gone (job function, setter, settings, shared function, the 'auto' column), the manual button works
-- again as 20261026120000 defined it, what an automatic run already took stays taken, a second run is harmless, and the migration applies again.
insert into auth.users (id, email) values ('a1000000-0000-0000-0000-0000000000a1', 'master@x'), ('b1000000-0000-0000-0000-0000000000b1', 'h1@x'), ('b2000000-0000-0000-0000-0000000000b2', 'h2@x');
insert into public.staff_roles (user_id, role) values ('a1000000-0000-0000-0000-0000000000a1', 'admin');
insert into public.wallet_ledger (profile_id, kind, currency, amount, created_at) values
  ('b1000000-0000-0000-0000-0000000000b1', 'gift_received', 'diamonds', 500, '2026-01-10 12:00+00'),
  ('b2000000-0000-0000-0000-0000000000b2', 'gift_received', 'diamonds', 300, '2026-02-10 12:00+00');
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-0000000000a1', false);
select public.admin_set_diamond_reset_auto(true, true, true, 1);
create temp table job1 as select public.run_diamond_reset_auto('2026-01-31 18:40+00') as r;
select '1 before: the job resets January (expect t, 500)' as check, (select (r ->> 'ran')::boolean from job1) as ran,
  (select diamonds from public.diamond_reset_runs where period = '2026-01' and source = 'gift' and auto) as taken;

\i supabase/rollbacks/20261026130000_down.sql

select '2 every automatic-reset object is gone (expect 0, 0)' as check,
  (select count(*) from pg_proc where proname in ('run_diamond_reset_auto', 'admin_set_diamond_reset_auto', '_diamond_reset_run_one')) as fns,
  (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'diamond_reset_settings') as settings;
select '3 the auto column is gone, the runs stay (expect 0 columns, 2 runs: gifting and the empty reward one)' as check,
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'diamond_reset_runs' and column_name = 'auto') as col,
  (select count(*) from public.diamond_reset_runs where period = '2026-01') as runs;
select '4 what the automatic run took stays taken (expect 0)' as check, (select diamonds from public.wallets where profile_id = 'b1000000-0000-0000-0000-0000000000b1') as h1;
select '5 the manual button works as before: February resets (expect 300)' as check,
  (public.admin_reset_diamonds('2026-02', 'gift', '2026-02') -> 0 ->> 'diamonds')::bigint as taken;

\i supabase/rollbacks/20261026130000_down.sql
select '6 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'run_diamond_reset_auto';

\i supabase/migrations/20261026130000_diamond_reset_auto.sql
select '7 re-applied: off by default again, and the job answers (expect f, off)' as check,
  (select enabled from public.diamond_reset_settings) as enabled, public.run_diamond_reset_auto('2026-01-31 18:40+00') ->> 'why' as why;
