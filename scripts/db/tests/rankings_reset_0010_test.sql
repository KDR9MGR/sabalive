-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/rankings_reset_0010_test.sql
-- Replaces rankings_india_time_test.sql (20261101020000, the midnight start). Proves (20261101120000): the day, week (Monday) and month of every leaderboard start at 00:10 India time, not at midnight. A gift at 00:09 (a minute before the
-- boundary) belongs to the period that is ending and one at 00:10:00 exactly, or a minute later, to the new one; the previous-period windows are exact; the panel's
-- admin_leaderboard returns the same people and scores as the app's nine boards, with the right ranks, tie order, totals and the previous period; only a Master or a
-- Super Admin can call it; a ghost never shows. Every line below ends in ok = t; the last line says ALL PASSED or lists how many failed.
-- production's database runs on UTC; the scratch server follows the computer's clock, so say UTC here
set time zone 'UTC';
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'send1@x'), ('a2000000-0000-0000-0000-000000000002', 'send2@x'), ('a3000000-0000-0000-0000-000000000003', 'send3@x'),
  ('a4000000-0000-0000-0000-000000000004', 'send4@x'),
  ('b1000000-0000-0000-0000-000000000001', 'host1@x'), ('b2000000-0000-0000-0000-000000000002', 'host2@x'), ('b3000000-0000-0000-0000-000000000003', 'host3@x'),
  ('b4000000-0000-0000-0000-000000000004', 'host4@x'), ('b5000000-0000-0000-0000-000000000005', 'host5@x'), ('b6000000-0000-0000-0000-000000000006', 'host6@x'),
  ('b7000000-0000-0000-0000-000000000007', 'ghost@x'),
  ('e1000000-0000-0000-0000-0000000000e1', 'master@x'), ('e2000000-0000-0000-0000-0000000000e2', 'super@x'), ('e3000000-0000-0000-0000-0000000000e3', 'global@x'),
  ('e4000000-0000-0000-0000-0000000000e4', 'plain@x');
insert into public.staff_roles (user_id, role) values
  ('e1000000-0000-0000-0000-0000000000e1', 'admin'), ('e2000000-0000-0000-0000-0000000000e2', 'super_admin'), ('e3000000-0000-0000-0000-0000000000e3', 'global_admin');
insert into public.agencies (id, name) values
  ('c1000000-0000-0000-0000-000000000001', 'Agency One'), ('c2000000-0000-0000-0000-000000000002', 'Agency Two'), ('c3000000-0000-0000-0000-000000000003', 'Agency Three');
insert into public.host_profiles (profile_id, agency_id, status) values
  ('b1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'active'),
  ('b2000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'active'),
  ('b3000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-000000000003', 'active'),
  ('b6000000-0000-0000-0000-000000000006', 'c3000000-0000-0000-0000-000000000003', 'active');
insert into public.gifts (id, name, emoji, price_coins) values ('d0000000-0000-0000-0000-000000000001', 'Rose', 'r', 1);
set session_replication_role = replica;
update public.profiles set is_ghost = true where id = 'b7000000-0000-0000-0000-000000000007';
set session_replication_role = origin;

create temp table r (n serial, check_name text, ok boolean);
create temp table b as select
  public.ist_period_start('day') as ds, public.ist_period_start('week') as ws, public.ist_period_start('month') as ms,
  -- plain arithmetic on the India clock: ten minutes back, to the start of the day / Monday / month, ten minutes forward
  ((((now() - interval '10 minutes') at time zone 'Asia/Kolkata')::date)::timestamp + interval '10 minutes') at time zone 'Asia/Kolkata' as ds_check,
  ((((now() - interval '10 minutes') at time zone 'Asia/Kolkata')::date - (extract(isodow from ((now() - interval '10 minutes') at time zone 'Asia/Kolkata'))::int - 1))::timestamp + interval '10 minutes') at time zone 'Asia/Kolkata' as ws_check,
  (date_trunc('month', (now() - interval '10 minutes') at time zone 'Asia/Kolkata') + interval '10 minutes') at time zone 'Asia/Kolkata' as ms_check;

-- 1. the helper
insert into r(check_name, ok) select '1 day, week (Monday) and month start at the 00:10 India moment, as plain arithmetic says', ds = ds_check and ws = ws_check and ms = ms_check from b;
insert into r(check_name, ok) select '1b they are 00:10 India time, and the week starts on a Monday and the month on the 1st',
       (ds at time zone 'Asia/Kolkata')::time = '00:10' and (ws at time zone 'Asia/Kolkata')::time = '00:10' and (ms at time zone 'Asia/Kolkata')::time = '00:10'
       and extract(isodow from ws at time zone 'Asia/Kolkata') = 1 and extract(day from ms at time zone 'Asia/Kolkata') = 1 from b;
insert into r(check_name, ok) select '1c not the midnight start of the previous migration, not the UTC start of the first version', ds <> date_trunc('day', now()) and ms <> date_trunc('month', now()) from b;
insert into r(check_name, ok) select '1d the current period has already begun and is less than a whole period old',
       ds <= now() and now() < ds + interval '1 day' and ws <= now() and now() < ws + interval '7 days' and ms <= now() and now() < ms + interval '32 days' from b;
insert into r(check_name, ok) select '1e the helper is not callable by app users',
       not has_function_privilege('authenticated', 'public.ist_period_start(text)', 'execute') and not has_function_privilege('anon', 'public.ist_period_start(text)', 'execute')
       and not has_function_privilege('authenticated', 'public.ist_period_bounds(text, integer)', 'execute');

-- 2. the windows
insert into r(check_name, ok) select '2 day windows: the current one is [start, start + 1 day), the previous one ends where the current one starts',
       (select starts_at = b.ds and ends_at = b.ds + interval '1 day' from public.ist_period_bounds('day', 0))
       and (select starts_at = b.ds - interval '1 day' and ends_at = b.ds from public.ist_period_bounds('day', 1)) from b;
insert into r(check_name, ok) select '2b week windows are seven days, starting on a Monday 00:10 India time',
       (select starts_at = b.ws and ends_at = b.ws + interval '7 days' from public.ist_period_bounds('week', 0))
       and (select ends_at = b.ws and ends_at - starts_at = interval '7 days' and extract(isodow from starts_at at time zone 'Asia/Kolkata') = 1 from public.ist_period_bounds('week', 1)) from b;
insert into r(check_name, ok) select '2c month windows: current starts the 1st 00:10, the previous one is the whole month before it (28 to 31 days), both end on a 1st 00:10',
       (select starts_at = b.ms and extract(day from ends_at at time zone 'Asia/Kolkata') = 1 and (ends_at at time zone 'Asia/Kolkata')::time = '00:10' from public.ist_period_bounds('month', 0))
       and (select ends_at = b.ms and extract(day from starts_at at time zone 'Asia/Kolkata') = 1 and (starts_at at time zone 'Asia/Kolkata')::time = '00:10'
                   and ends_at - starts_at between interval '28 days' and interval '31 days' from public.ist_period_bounds('month', 1)) from b;
create function pg_temp.bounds_fails(p text) returns boolean language plpgsql as $$ begin perform * from public.ist_period_bounds(p, 0); return false; exception when others then return true; end $$;
insert into r(check_name, ok) select '2e bounds for "year" or nothing raise', pg_temp.bounds_fails('year') and pg_temp.bounds_fails('x');

-- 3. gifts around each boundary. Host / sender / agency 1 = month, 2 = week, 3 = day (host 3 also: a gift AT the boundary); hosts 4 and 5 tie, 5 got there first.
insert into public.gift_transactions (sender_id, receiver_id, gift_id, coins, created_at)
select s, rc, 'd0000000-0000-0000-0000-000000000001', c, t from b, lateral (values
  ('a1000000-0000-0000-0000-000000000001'::uuid, 'b1000000-0000-0000-0000-000000000001'::uuid, 1000, ms - interval '1 minute'),
  ('a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 2000, ms + interval '1 minute'),
  ('a2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', 30,   ws - interval '1 minute'),
  ('a2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', 60,   ws + interval '1 minute'),
  ('a3000000-0000-0000-0000-000000000003', 'b3000000-0000-0000-0000-000000000003', 400,  ds - interval '1 minute'),
  ('a3000000-0000-0000-0000-000000000003', 'b3000000-0000-0000-0000-000000000003', 800,  ds + interval '1 minute'),
  ('a3000000-0000-0000-0000-000000000003', 'b3000000-0000-0000-0000-000000000003', 100,  ds),
  ('a3000000-0000-0000-0000-000000000003', 'b6000000-0000-0000-0000-000000000006', 50,   ds + interval '5 minutes'),
  ('a4000000-0000-0000-0000-000000000004', 'b4000000-0000-0000-0000-000000000004', 500,  ds + interval '3 minutes'),
  ('a4000000-0000-0000-0000-000000000004', 'b5000000-0000-0000-0000-000000000005', 500,  ds + interval '2 minutes')
) as v(s, rc, c, t);
-- a gift sent to a ghost (only a direct insert can do it: the live flow never offers one)
set session_replication_role = replica;
insert into public.gift_transactions (sender_id, receiver_id, gift_id, coins, created_at)
values ('a4000000-0000-0000-0000-000000000004', 'b7000000-0000-0000-0000-000000000007', 'd0000000-0000-0000-0000-000000000001', 7777, (select ds from b) + interval '4 minutes');
set session_replication_role = origin;

-- hosts (diamonds received)
insert into r(check_name, ok) select '3 hosts: month board counts the gift after the boundary and not the one before (2000)', (select score from public.rankings_monthly() where profile_id = 'b1000000-0000-0000-0000-000000000001') = 2000;
insert into r(check_name, ok) select '3b hosts: week board (60)', (select score from public.rankings_weekly() where profile_id = 'b2000000-0000-0000-0000-000000000002') = 60;
insert into r(check_name, ok) select '3c hosts: day board counts +1 minute and the gift AT 00:10:00, not the minute before (900)', (select score from public.rankings_daily() where profile_id = 'b3000000-0000-0000-0000-000000000003') = 900;
-- gifters (coins spent)
insert into r(check_name, ok) select '4 gifters: month / week / day (2000, 60, 950)',
       (select score from public.rankings_top_gifters_monthly() where profile_id = 'a1000000-0000-0000-0000-000000000001') = 2000
       and (select score from public.rankings_top_gifters_weekly() where profile_id = 'a2000000-0000-0000-0000-000000000002') = 60
       and (select score from public.rankings_top_gifters_daily() where profile_id = 'a3000000-0000-0000-0000-000000000003') = 950;
-- agencies (all of their hosts' diamonds together)
insert into r(check_name, ok) select '5 agencies: month / week (2000, 60); agency 3 adds its two hosts together (900 + 50 = 950)',
       (select score from public.rankings_agencies_monthly() where agency_id = 'c1000000-0000-0000-0000-000000000001') = 2000
       and (select score from public.rankings_agencies_weekly() where agency_id = 'c2000000-0000-0000-0000-000000000002') = 60
       and (select score from public.rankings_agencies_daily() where agency_id = 'c3000000-0000-0000-0000-000000000003') = 950;
insert into r(check_name, ok) select '5b the earlier-month gift is out of the month board but still in all-time (3000)',
       (select score from public.rankings_all_time() where profile_id = 'b1000000-0000-0000-0000-000000000001') = 3000;
insert into r(check_name, ok) select '5c the app boards are still readable by the app roles',
       bool_and(has_function_privilege('authenticated', p.oid, 'execute') and has_function_privilege('anon', p.oid, 'execute')) and count(*) = 9
  from pg_proc p where p.pronamespace = 'public'::regnamespace
   and p.proname in ('rankings_daily','rankings_weekly','rankings_monthly','rankings_top_gifters_daily','rankings_top_gifters_weekly','rankings_top_gifters_monthly',
                     'rankings_agencies_daily','rankings_agencies_weekly','rankings_agencies_monthly');

-- 6. the panel reader. Act as a Master.
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e1', false);
create function pg_temp.lb(b text, p text, w text default 'current', l integer default 500) returns jsonb language sql as $$ select public.admin_leaderboard(b, p, w, l) $$;
create function pg_temp.row_of(j jsonb, id text) returns jsonb language sql as $$ select e from jsonb_array_elements(j -> 'rows') e where e ->> 'id' = id $$;

insert into r(check_name, ok) select '6 the window shown on the page is the same as the helper''s',
       (pg_temp.lb('hosts', 'day') ->> 'starts_at')::timestamptz = (select ds from b)
       and (pg_temp.lb('hosts', 'week') ->> 'starts_at')::timestamptz = (select ws from b)
       and (pg_temp.lb('hosts', 'month') ->> 'starts_at')::timestamptz = (select ms from b)
       and (pg_temp.lb('hosts', 'day') ->> 'ends_at')::timestamptz = (select ds from b) + interval '1 day';
insert into r(check_name, ok) select '6b hosts: scores, the person''s app User ID, name and agency',
       (pg_temp.row_of(pg_temp.lb('hosts', 'day'), 'b3000000-0000-0000-0000-000000000003') ->> 'score')::bigint = 900
       and (pg_temp.row_of(pg_temp.lb('hosts', 'day'), 'b3000000-0000-0000-0000-000000000003') ->> 'gifts')::int = 2
       and (pg_temp.row_of(pg_temp.lb('hosts', 'day'), 'b3000000-0000-0000-0000-000000000003') ->> 'agency') = 'Agency Three'
       and (pg_temp.row_of(pg_temp.lb('hosts', 'day'), 'b3000000-0000-0000-0000-000000000003') ->> 'user_id') is not distinct from
           (select display_id::text from public.profiles where id = 'b3000000-0000-0000-0000-000000000003')
       and (pg_temp.row_of(pg_temp.lb('hosts', 'day'), 'b3000000-0000-0000-0000-000000000003') ->> 'name') is not distinct from
           (select name from public.profiles where id = 'b3000000-0000-0000-0000-000000000003');
insert into r(check_name, ok) select '6c gifters: coins spent (950 for sender 3 in the day, 2000 for sender 1 in the month)',
       (pg_temp.row_of(pg_temp.lb('gifters', 'day'), 'a3000000-0000-0000-0000-000000000003') ->> 'score')::bigint = 950
       and (pg_temp.row_of(pg_temp.lb('gifters', 'month'), 'a1000000-0000-0000-0000-000000000001') ->> 'score')::bigint = 2000;
insert into r(check_name, ok) select '6d agencies: the two hosts of agency 3 are added together (950) and counted (2 hosts)',
       (pg_temp.row_of(pg_temp.lb('agencies', 'day'), 'c3000000-0000-0000-0000-000000000003') ->> 'score')::bigint = 950
       and (pg_temp.row_of(pg_temp.lb('agencies', 'day'), 'c3000000-0000-0000-0000-000000000003') ->> 'hosts')::int = 2
       and (pg_temp.row_of(pg_temp.lb('agencies', 'day'), 'c3000000-0000-0000-0000-000000000003') ->> 'name') = 'Agency Three';
insert into r(check_name, ok) select '6e a tie goes to whoever reached the score first (host 5 before host 4), and ranks count up from 1 with no gaps',
       (select (e ->> 'rank')::int from jsonb_array_elements(pg_temp.lb('hosts', 'day') -> 'rows') e where e ->> 'id' = 'b5000000-0000-0000-0000-000000000005')
       < (select (e ->> 'rank')::int from jsonb_array_elements(pg_temp.lb('hosts', 'day') -> 'rows') e where e ->> 'id' = 'b4000000-0000-0000-0000-000000000004')
       and (select array_agg((e ->> 'rank')::int order by ord) = array(select generate_series(1, jsonb_array_length(pg_temp.lb('hosts', 'day') -> 'rows')))
              from jsonb_array_elements(pg_temp.lb('hosts', 'day') -> 'rows') with ordinality t(e, ord));
insert into r(check_name, ok) select '6f a ghost never shows, and does not count in the total',
       pg_temp.row_of(pg_temp.lb('hosts', 'day'), 'b7000000-0000-0000-0000-000000000007') is null
       and (pg_temp.lb('hosts', 'day') ->> 'total')::bigint = (select sum(coins) from public.gift_transactions, b where created_at >= b.ds and created_at < b.ds + interval '1 day' and receiver_id <> 'b7000000-0000-0000-0000-000000000007');
insert into r(check_name, ok) select '6g entries and total cover everybody even when only the first rows are asked for',
       (pg_temp.lb('hosts', 'day', 'current', 2) ->> 'entries')::int = (select count(distinct receiver_id) from public.gift_transactions, b where created_at >= b.ds and created_at < b.ds + interval '1 day' and receiver_id <> 'b7000000-0000-0000-0000-000000000007')
       and jsonb_array_length(pg_temp.lb('hosts', 'day', 'current', 2) -> 'rows') = 2
       and (pg_temp.lb('hosts', 'day', 'current', 2) ->> 'total') = (pg_temp.lb('hosts', 'day') ->> 'total');
insert into r(check_name, ok) select '6h the previous period holds what the current one left out',
       (pg_temp.row_of(pg_temp.lb('hosts', 'day', 'previous'), 'b3000000-0000-0000-0000-000000000003') ->> 'score')::bigint = 400
       and (pg_temp.row_of(pg_temp.lb('hosts', 'week', 'previous'), 'b2000000-0000-0000-0000-000000000002') ->> 'score')::bigint = 30
       and (pg_temp.row_of(pg_temp.lb('hosts', 'month', 'previous'), 'b1000000-0000-0000-0000-000000000001') ->> 'score')::bigint = 1000
       and (pg_temp.lb('hosts', 'day', 'previous') ->> 'ends_at')::timestamptz = (select ds from b);
insert into r(check_name, ok) select '6i the current board does not show the previous period''s gifts, and the previous one does not show this one''s',
       (pg_temp.row_of(pg_temp.lb('hosts', 'month', 'previous'), 'b1000000-0000-0000-0000-000000000001') ->> 'score')::bigint <> 2000
       and (pg_temp.row_of(pg_temp.lb('hosts', 'week'), 'b2000000-0000-0000-0000-000000000002') ->> 'score')::bigint = 60;

-- 7. the panel's numbers are the app's numbers, board by board (everything except the ghost)
create function pg_temp.same(panel jsonb, app_ids uuid[], app_scores bigint[]) returns boolean language sql as $$
  select not exists (
    (select (e ->> 'id')::uuid, (e ->> 'score')::bigint from jsonb_array_elements(panel -> 'rows') e
     except select u.i, u.s from unnest(app_ids, app_scores) as u(i, s) where u.i <> 'b7000000-0000-0000-0000-000000000007')
    union all
    (select u.i, u.s from unnest(app_ids, app_scores) as u(i, s) where u.i <> 'b7000000-0000-0000-0000-000000000007'
     except select (e ->> 'id')::uuid, (e ->> 'score')::bigint from jsonb_array_elements(panel -> 'rows') e))
$$;
insert into r(check_name, ok) select '7 hosts day / week / month: the panel equals the app',
       pg_temp.same(pg_temp.lb('hosts', 'day'),   array(select profile_id from public.rankings_daily()),   array(select score from public.rankings_daily()))
   and pg_temp.same(pg_temp.lb('hosts', 'week'),  array(select profile_id from public.rankings_weekly()),  array(select score from public.rankings_weekly()))
   and pg_temp.same(pg_temp.lb('hosts', 'month'), array(select profile_id from public.rankings_monthly()), array(select score from public.rankings_monthly()));
insert into r(check_name, ok) select '7b gifters day / week / month: the panel equals the app',
       pg_temp.same(pg_temp.lb('gifters', 'day'),   array(select profile_id from public.rankings_top_gifters_daily()),   array(select score from public.rankings_top_gifters_daily()))
   and pg_temp.same(pg_temp.lb('gifters', 'week'),  array(select profile_id from public.rankings_top_gifters_weekly()),  array(select score from public.rankings_top_gifters_weekly()))
   and pg_temp.same(pg_temp.lb('gifters', 'month'), array(select profile_id from public.rankings_top_gifters_monthly()), array(select score from public.rankings_top_gifters_monthly()));
insert into r(check_name, ok) select '7c agencies day / week / month: the panel equals the app',
       pg_temp.same(pg_temp.lb('agencies', 'day'),   array(select agency_id from public.rankings_agencies_daily()),   array(select score from public.rankings_agencies_daily()))
   and pg_temp.same(pg_temp.lb('agencies', 'week'),  array(select agency_id from public.rankings_agencies_weekly()),  array(select score from public.rankings_agencies_weekly()))
   and pg_temp.same(pg_temp.lb('agencies', 'month'), array(select agency_id from public.rankings_agencies_monthly()), array(select score from public.rankings_agencies_monthly()));

-- 8. who may call it
create function pg_temp.allowed(who text) returns boolean language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(who, ''), false);
  perform public.admin_leaderboard('hosts', 'day', 'current', 5);
  return true;
exception when others then return false;
end $$;
insert into r(check_name, ok) select '8 a Master and a Super Admin may; a Global Admin, a plain user and nobody signed in may not',
       pg_temp.allowed('e1000000-0000-0000-0000-0000000000e1') and pg_temp.allowed('e2000000-0000-0000-0000-0000000000e2')
       and not pg_temp.allowed('e3000000-0000-0000-0000-0000000000e3') and not pg_temp.allowed('e4000000-0000-0000-0000-0000000000e4') and not pg_temp.allowed(null);
insert into r(check_name, ok) select '8b the reader is open to signed-in callers only at the grant level (not anon, not public)',
       has_function_privilege('authenticated', 'public.admin_leaderboard(text, text, text, integer)', 'execute')
       and not has_function_privilege('anon', 'public.admin_leaderboard(text, text, text, integer)', 'execute');
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e1', false);
create function pg_temp.fails(b text, p text, w text) returns boolean language plpgsql as $$ begin perform public.admin_leaderboard(b, p, w, 5); return false; exception when others then return true; end $$;
insert into r(check_name, ok) select '8c an unknown board, period or choice is refused',
       pg_temp.fails('players', 'day', 'current') and pg_temp.fails('hosts', 'year', 'current') and pg_temp.fails('hosts', 'day', 'next') and pg_temp.fails(null, 'day', 'current');
insert into r(check_name, ok) select '8d a limit is kept between 1 and 500',
       jsonb_array_length(public.admin_leaderboard('hosts', 'day', 'current', 0) -> 'rows') = 1
       and jsonb_array_length(public.admin_leaderboard('hosts', 'day', 'current', -3) -> 'rows') = 1;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
