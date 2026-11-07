-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/live_hearts_test.sql
-- Proves (20261107120000_live_hearts): hearts from several people add up in ONE row per live (total, who added last and how many); a call adds 1..100 (more is cut, 0 / negative / null add
-- nothing); a live that is over takes none; a ghost, a signed-out caller and a stream that does not exist are refused; signed-in users can read the total and nobody can write the table
-- directly; the row goes with its live. Every line ends in ok = t; the last line says ALL PASSED or how many failed.
set time zone 'UTC';
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'one@x'), ('a2000000-0000-0000-0000-000000000002', 'two@x'), ('a3000000-0000-0000-0000-000000000003', 'ghost@x'), ('a4000000-0000-0000-0000-000000000004', 'host@x');
set session_replication_role = replica;
update public.profiles set is_ghost = true where id = 'a3000000-0000-0000-0000-000000000003';
set session_replication_role = origin;
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at) values
  ('f1000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000004', 'live room', 'live', 'audio', now(), now()),
  ('f2000000-0000-0000-0000-000000000002', 'a4000000-0000-0000-0000-000000000004', 'ended room', 'ended', 'audio', now(), now());

create temp table r (n serial, check_name text, ok boolean);
grant all on r to authenticated, anon;
grant usage, select on sequence r_n_seq to authenticated, anon;
create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;
create function pg_temp.as_user(u uuid) returns void language plpgsql as $$ begin perform set_config('request.jwt.claim.sub', u::text, false); end $$;
create function pg_temp.refused(sql text, expected text) returns boolean language plpgsql as $$ begin execute sql; return false; exception when others then return sqlerrm like '%' || expected || '%'; end $$;

set role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000001');
insert into ctx values ('t1', public.add_live_hearts('f1000000-0000-0000-0000-000000000001', 5)::text);
insert into r(check_name, ok) select '1 the first hearts make the row: the total is what was sent', (select v from ctx where k = 't1') = '5';

select pg_temp.as_user('a2000000-0000-0000-0000-000000000002');
insert into ctx values ('t2', public.add_live_hearts('f1000000-0000-0000-0000-000000000001', 7)::text);
insert into r(check_name, ok) select '2 hearts from a second person ADD to it (the sum of everybody)', (select v from ctx where k = 't2') = '12';
insert into r(check_name, ok) select '3 the row says who added last and how many',
  (select (last_by, last_count)::text from public.live_hearts where live_stream_id = 'f1000000-0000-0000-0000-000000000001') = '(a2000000-0000-0000-0000-000000000002,7)';

insert into ctx values ('t3', public.add_live_hearts('f1000000-0000-0000-0000-000000000001', 5000)::text);
insert into r(check_name, ok) select '4 one call adds at most 100 (the rest is cut)', (select v from ctx where k = 't3') = '112';

insert into ctx values ('t4', public.add_live_hearts('f1000000-0000-0000-0000-000000000001', 0)::text), ('t5', public.add_live_hearts('f1000000-0000-0000-0000-000000000001', -3)::text), ('t6', public.add_live_hearts('f1000000-0000-0000-0000-000000000001', null)::text);
insert into r(check_name, ok) select '5 0, a negative count and null add nothing and return the total as it is', (select v from ctx where k in ('t4', 't5', 't6') group by v) = '112' and (select count(distinct v) from ctx where k in ('t4','t5','t6')) = 1;

insert into ctx values ('t7', public.add_live_hearts('f2000000-0000-0000-0000-000000000002', 10)::text);
insert into r(check_name, ok) select '6 a live that is over takes no hearts (returns 0, no row)', (select v from ctx where k = 't7') = '0'
  and not exists (select 1 from public.live_hearts where live_stream_id = 'f2000000-0000-0000-0000-000000000002');

insert into r(check_name, ok) select '7 a stream that does not exist is refused', pg_temp.refused($q$select public.add_live_hearts('99999999-0000-0000-0000-000000000009', 1)$q$, 'does not exist');

select pg_temp.as_user('a3000000-0000-0000-0000-000000000003');
insert into r(check_name, ok) select '8 a ghost (monitoring) account cannot send hearts', pg_temp.refused($q$select public.add_live_hearts('f1000000-0000-0000-0000-000000000001', 1)$q$, 'cannot send hearts');

select pg_temp.as_user('a1000000-0000-0000-0000-000000000001');
insert into r(check_name, ok) select '9 a signed-in user can read a live''s total', (select total from public.live_hearts where live_stream_id = 'f1000000-0000-0000-0000-000000000001') = 112;
insert into r(check_name, ok) select '10 nobody from the app can write, change or delete the table directly',
  pg_temp.refused($q$insert into public.live_hearts (live_stream_id, total) values ('f2000000-0000-0000-0000-000000000002', 5)$q$, 'permission denied')
  and pg_temp.refused($q$update public.live_hearts set total = 1$q$, 'permission denied')
  and pg_temp.refused($q$delete from public.live_hearts$q$, 'permission denied');
reset role;

set role anon;
insert into r(check_name, ok) select '11 a signed-out caller can neither call the function nor read the table',
  pg_temp.refused($q$select public.add_live_hearts('f1000000-0000-0000-0000-000000000001', 1)$q$, 'permission denied')
  and pg_temp.refused($q$select * from public.live_hearts$q$, 'permission denied');
reset role;

delete from public.live_streams where id = 'f1000000-0000-0000-0000-000000000001';
insert into r(check_name, ok) select '12 the row goes with its live', not exists (select 1 from public.live_hearts where live_stream_id = 'f1000000-0000-0000-0000-000000000001');

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
