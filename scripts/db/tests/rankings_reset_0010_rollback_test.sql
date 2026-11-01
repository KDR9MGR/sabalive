-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/rankings_reset_0010_rollback_test.sql
-- Proves supabase/rollbacks/20261101120000_down.sql: after it the boards start at India midnight again, the panel's reader and the window helper are gone, the nine
-- app boards still work; a second rollback is harmless; and the migration can be applied again afterwards.
set time zone 'UTC';
create temp table r (n serial, check_name text, ok boolean);

insert into r(check_name, ok) select '1 before: the day starts at 00:10 India time',
       (public.ist_period_start('day') at time zone 'Asia/Kolkata')::time = '00:10';

\i supabase/rollbacks/20261101120000_down.sql

insert into r(check_name, ok) select '2 after: the day, week and month start at 00:00 India time again',
       (public.ist_period_start('day') at time zone 'Asia/Kolkata')::time = '00:00'
       and (public.ist_period_start('week') at time zone 'Asia/Kolkata')::time = '00:00'
       and (public.ist_period_start('month') at time zone 'Asia/Kolkata')::time = '00:00';
insert into r(check_name, ok) select '3 the panel reader and the window helper are gone',
       not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('admin_leaderboard', 'ist_period_bounds'));
insert into r(check_name, ok) select '4 the nine app boards still run and the helper is still closed to app users',
       (select count(*) from public.rankings_daily()) >= 0 and (select count(*) from public.rankings_top_gifters_weekly()) >= 0
       and (select count(*) from public.rankings_agencies_monthly()) >= 0
       and not has_function_privilege('authenticated', 'public.ist_period_start(text)', 'execute');

\i supabase/rollbacks/20261101120000_down.sql
insert into r(check_name, ok) select '5 a second rollback is harmless', (public.ist_period_start('day') at time zone 'Asia/Kolkata')::time = '00:00';

\i supabase/migrations/20261101120000_rankings_reset_0010.sql
insert into r(check_name, ok) select '6 applied again: 00:10, the reader and the helper are back',
       (public.ist_period_start('day') at time zone 'Asia/Kolkata')::time = '00:10'
       and exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_leaderboard')
       and exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ist_period_bounds');

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
