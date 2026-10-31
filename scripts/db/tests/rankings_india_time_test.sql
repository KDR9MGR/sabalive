-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/rankings_india_time_test.sql
-- Proves (20261101020000): the day, week and month of every leaderboard start at INDIA midnight (Monday for the week), not at UTC midnight. Gifts are placed
-- exactly one minute before and one minute after each India boundary: the one before belongs to the previous period and is left out, the one after
-- counts. That second gift is the one the old UTC windows lost for 5 hours 30 minutes after every India midnight. Hosts, gifters and agencies are all
-- checked; the helper is not callable by app users; the boards are still callable by the app's roles and return the same columns.
-- production's database runs on UTC (the old boards cut at UTC midnight); the scratch server follows the computer's clock, so say UTC here
set time zone 'UTC';
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'send1@x'), ('a2000000-0000-0000-0000-000000000002', 'send2@x'), ('a3000000-0000-0000-0000-000000000003', 'send3@x'),
  ('b1000000-0000-0000-0000-000000000001', 'host1@x'), ('b2000000-0000-0000-0000-000000000002', 'host2@x'), ('b3000000-0000-0000-0000-000000000003', 'host3@x');
insert into public.agencies (id, name) values
  ('c1000000-0000-0000-0000-000000000001', 'Agency One'), ('c2000000-0000-0000-0000-000000000002', 'Agency Two'), ('c3000000-0000-0000-0000-000000000003', 'Agency Three');
insert into public.host_profiles (profile_id, agency_id, status) values
  ('b1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'active'),
  ('b2000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'active'),
  ('b3000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-000000000003', 'active');
insert into public.gifts (id, name, emoji, price_coins) values ('d0000000-0000-0000-0000-000000000001', 'Rose', 'r', 1);

-- 1. the helper agrees with plain arithmetic on India time
create temp table b as select
  public.ist_period_start('day') as ds, public.ist_period_start('week') as ws, public.ist_period_start('month') as ms,
  (((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata') as ds_check,
  (((now() at time zone 'Asia/Kolkata')::date - (extract(isodow from (now() at time zone 'Asia/Kolkata'))::int - 1))::timestamp at time zone 'Asia/Kolkata') as ws_check,
  ((date_trunc('month', now() at time zone 'Asia/Kolkata'))::timestamp at time zone 'Asia/Kolkata') as ms_check;
select '1 day, week (Monday) and month start at India midnight (expect t, t, t)' as check, ds = ds_check as day_ok, ws = ws_check as week_ok, ms = ms_check as month_ok from b;
select '1b they are not the UTC starts the old boards used (expect t, t, t)' as check, ds <> date_trunc('day', now()) as day_differs, ws <> date_trunc('week', now()) as week_differs, ms <> date_trunc('month', now()) as month_differs from b;
select '1c an India boundary is a moment of 00:00 India time (expect t, t, t)' as check,
       (ds at time zone 'Asia/Kolkata')::time = '00:00' as day_midnight, (ws at time zone 'Asia/Kolkata')::time = '00:00' as week_midnight,
       (ms at time zone 'Asia/Kolkata')::time = '00:00' and extract(day from ms at time zone 'Asia/Kolkata') = 1 as month_first_midnight from b;

-- 2. gifts a minute either side of each boundary. Host/sender/agency 1 = month, 2 = week, 3 = day.
insert into public.gift_transactions (sender_id, receiver_id, gift_id, coins, created_at)
select s, r, 'd0000000-0000-0000-0000-000000000001', c, t from b, lateral (values
  ('a1000000-0000-0000-0000-000000000001'::uuid, 'b1000000-0000-0000-0000-000000000001'::uuid, 1000, ms - interval '1 minute'),
  ('a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 2000, ms + interval '1 minute'),
  ('a2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', 30,   ws - interval '1 minute'),
  ('a2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', 60,   ws + interval '1 minute'),
  ('a3000000-0000-0000-0000-000000000003', 'b3000000-0000-0000-0000-000000000003', 400,  ds - interval '1 minute'),
  ('a3000000-0000-0000-0000-000000000003', 'b3000000-0000-0000-0000-000000000003', 800,  ds + interval '1 minute')
) as v(s, r, c, t);

select '2 hosts: the month board counts the gift after India midnight and not the one before (expect 2000)' as check,
       (select score from public.rankings_monthly() where profile_id = 'b1000000-0000-0000-0000-000000000001') as n;
select '2b hosts: the week board (expect 60)' as check, (select score from public.rankings_weekly() where profile_id = 'b2000000-0000-0000-0000-000000000002') as n;
select '2c hosts: the day board (expect 800)' as check, (select score from public.rankings_daily() where profile_id = 'b3000000-0000-0000-0000-000000000003') as n;
select '3 gifters: month / week / day (expect 2000, 60, 800)' as check,
       (select score from public.rankings_top_gifters_monthly() where profile_id = 'a1000000-0000-0000-0000-000000000001') as month,
       (select score from public.rankings_top_gifters_weekly()  where profile_id = 'a2000000-0000-0000-0000-000000000002') as week,
       (select score from public.rankings_top_gifters_daily()   where profile_id = 'a3000000-0000-0000-0000-000000000003') as day;
select '4 agencies: month / week / day (expect 2000, 60, 800)' as check,
       (select score from public.rankings_agencies_monthly() where agency_id = 'c1000000-0000-0000-0000-000000000001') as month,
       (select score from public.rankings_agencies_weekly()  where agency_id = 'c2000000-0000-0000-0000-000000000002') as week,
       (select score from public.rankings_agencies_daily()   where agency_id = 'c3000000-0000-0000-0000-000000000003') as day;

-- 5. a gift sent just before the new India month is NOT in the new month's board, and is still in all-time
select '5 the previous month gift (1000) is left out of the month board but kept in all-time (expect 2000, 3000)' as check,
       (select score from public.rankings_monthly()  where profile_id = 'b1000000-0000-0000-0000-000000000001') as month,
       (select score from public.rankings_all_time() where profile_id = 'b1000000-0000-0000-0000-000000000001') as all_time;

-- 6. nothing else changed: same columns, still open to the app's roles, the helper is not
select '6 the host boards return (profile_id, score) and the agency boards (agency_id, agency_name, score) (expect t, t)' as check,
       (select pg_get_function_result('public.rankings_monthly()'::regprocedure) = 'TABLE(profile_id uuid, score bigint)') as hosts,
       (select pg_get_function_result('public.rankings_agencies_monthly()'::regprocedure) = 'TABLE(agency_id uuid, agency_name text, score bigint)') as agencies;
select '6b the app roles can still read all nine boards (expect t)' as check,
       bool_and(has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('anon', p.oid, 'execute')) as ok, count(*) as boards
  from pg_proc p where p.pronamespace = 'public'::regnamespace
   and p.proname in ('rankings_daily','rankings_weekly','rankings_monthly','rankings_top_gifters_daily','rankings_top_gifters_weekly','rankings_top_gifters_monthly',
                     'rankings_agencies_daily','rankings_agencies_weekly','rankings_agencies_monthly');
select '6c the helper is not callable by app users (expect f, f)' as check,
       has_function_privilege('authenticated', 'public.ist_period_start(text)', 'execute') as authed,
       has_function_privilege('anon', 'public.ist_period_start(text)', 'execute') as anon;
