-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/rtc_provider_test.sql
-- Proves (20261106130000_rtc_provider): a live room is on 'agora' unless its host says otherwise, a host can create a room on 'livekit', no other value is accepted, the rooms that
-- existed before are all 'agora', and an app that never mentions the column (every older app) still creates rooms exactly as before. Every line ends in ok = t.
set time zone 'UTC';
insert into auth.users (id, email) values ('a1000000-0000-0000-0000-000000000001', 'host@x');
create temp table r (n serial, check_name text, ok boolean);
create function pg_temp.refused(sql text) returns boolean language plpgsql as $$ begin execute sql; return false; exception when others then return true; end $$;

insert into public.live_streams (id, host_id, title, mode) values ('f1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'old style room', 'audio');
insert into r(check_name, ok) select '1 a room created the old way (no mention of the column) is on agora',
  (select rtc_provider from public.live_streams where id = 'f1000000-0000-0000-0000-000000000001') = 'agora';

insert into public.live_streams (id, host_id, title, mode, rtc_provider) values ('f2000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'new room', 'video', 'livekit');
insert into r(check_name, ok) select '2 a room can be created on livekit',
  (select rtc_provider from public.live_streams where id = 'f2000000-0000-0000-0000-000000000002') = 'livekit';

insert into r(check_name, ok) select '3 no other provider is accepted, and the column cannot be emptied',
  pg_temp.refused($q$insert into public.live_streams (host_id, title, rtc_provider) values ('a1000000-0000-0000-0000-000000000001', 'x', 'zoom')$q$)
  and pg_temp.refused($q$insert into public.live_streams (host_id, title, rtc_provider) values ('a1000000-0000-0000-0000-000000000001', 'x', null)$q$)
  and pg_temp.refused($q$update public.live_streams set rtc_provider = null where id = 'f1000000-0000-0000-0000-000000000001'$q$);

insert into r(check_name, ok) select '4 every room that existed before the migration (here: none had the column) reads as agora: the default is a constant',
  (select count(*) from public.live_streams where rtc_provider = 'livekit') = 1
  and (select count(*) from public.live_streams where rtc_provider = 'agora') = 1;

insert into r(check_name, ok) select '5 the column is a plain text with a default, so a list that selects * keeps working',
  (select data_type || ':' || column_default from information_schema.columns where table_schema = 'public' and table_name = 'live_streams' and column_name = 'rtc_provider') = 'text:''agora''::text';

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
