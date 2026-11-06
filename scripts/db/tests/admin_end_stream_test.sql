-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/admin_end_stream_test.sql
-- Proves (20261106100000_admin_end_stream): Super Admin and a Master who was granted `monitor_lives` end a live and it is audited; the live is then 'ended' with an ended_at; the same call again
-- changes nothing and logs nothing; a Master with no grant (a Master needs `monitor_lives` switched on by a Super Admin since 20261006160000) or with it off, a Global Admin without the grant, a Global Admin WITH the grant, a plain
-- user, a host (their own live) and a signed-out caller get what the Watch button's rule says; an unknown live is refused; a live that is already over is
-- never touched. Every line says what to expect.
insert into auth.users (id, email) values
  ('e6000001-0000-0000-0000-000000000001', 'super6@x'),
  ('e6000002-0000-0000-0000-000000000002', 'master6@x'),
  ('e6000003-0000-0000-0000-000000000003', 'masteroff6@x'),
  ('e6000004-0000-0000-0000-000000000004', 'global6@x'),
  ('e6000005-0000-0000-0000-000000000005', 'globalgrant6@x'),
  ('e6000006-0000-0000-0000-000000000006', 'plain6@x'),
  ('e6000007-0000-0000-0000-000000000007', 'host6@x'),
  ('e6000008-0000-0000-0000-000000000008', 'masterdefault6@x');
insert into public.staff_roles (user_id, role, permissions) values
  ('e6000001-0000-0000-0000-000000000001', 'super_admin', '{}'),
  ('e6000002-0000-0000-0000-000000000002', 'admin', '{"monitor_lives": true}'),
  ('e6000008-0000-0000-0000-000000000008', 'admin', '{}'),
  ('e6000003-0000-0000-0000-000000000003', 'admin', '{"monitor_lives": false}'),
  ('e6000004-0000-0000-0000-000000000004', 'global_admin', '{}'),
  ('e6000005-0000-0000-0000-000000000005', 'global_admin', '{"monitor_lives": true}');
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at) values
  ('e6aaaaaa-0000-0000-0000-000000000001', 'e6000007-0000-0000-0000-000000000007', 'room one', 'live', 'audio', now(), now()),
  ('e6aaaaaa-0000-0000-0000-000000000002', 'e6000007-0000-0000-0000-000000000007', 'room two', 'live', 'video', now(), now()),
  ('e6aaaaaa-0000-0000-0000-000000000003', 'e6000007-0000-0000-0000-000000000007', 'room three', 'live', 'audio', now(), now()),
  ('e6aaaaaa-0000-0000-0000-000000000004', 'e6000007-0000-0000-0000-000000000007', 'already over', 'ended', 'audio', now() - interval '1 hour', now() - interval '1 hour');
update public.live_streams set ended_at = now() - interval '30 minutes' where id = 'e6aaaaaa-0000-0000-0000-000000000004';

-- 1. Super Admin ends room one
set role authenticated;
select set_config('request.jwt.claim.sub', 'e6000001-0000-0000-0000-000000000001', false);
select '1 Super Admin ends it (expect {"ended": true, "host_id": ...})' as check, public.admin_end_stream('e6aaaaaa-0000-0000-0000-000000000001') as result;
reset role;
select '1b it is ended with a time, the others are still live (expect ended, t, live, live)' as check,
       (select status from public.live_streams where id = 'e6aaaaaa-0000-0000-0000-000000000001') as one,
       (select ended_at is not null from public.live_streams where id = 'e6aaaaaa-0000-0000-0000-000000000001') as stamped,
       (select status from public.live_streams where id = 'e6aaaaaa-0000-0000-0000-000000000002') as two,
       (select status from public.live_streams where id = 'e6aaaaaa-0000-0000-0000-000000000003') as three;
select '1c one audit row, by Super Admin, warning, naming the stream, host and title (expect 1, t, warning, t)' as check,
       (select count(*) from public.audit_logs where action = 'live.killed') as rows,
       (select actor_id = 'e6000001-0000-0000-0000-000000000001' from public.audit_logs where action = 'live.killed') as actor,
       (select severity from public.audit_logs where action = 'live.killed') as sev,
       (select target like 'e6aaaaaa-0000-0000-0000-000000000001 host e6000007-%"room one"' from public.audit_logs where action = 'live.killed') as target;

-- 2. the same call again changes nothing and adds no audit row
set role authenticated;
select '2 again on the same live (expect {"ended": false, "reason": "already_ended"})' as check, public.admin_end_stream('e6aaaaaa-0000-0000-0000-000000000001') as result;
reset role;
select '2b still exactly one audit row (expect 1)' as check, count(*) as rows from public.audit_logs where action = 'live.killed';

-- 3. a Master who was granted monitor_lives ends room two
set role authenticated;
select set_config('request.jwt.claim.sub', 'e6000002-0000-0000-0000-000000000002', false);
select '3 a Master ends room two (expect ended true)' as check, (public.admin_end_stream('e6aaaaaa-0000-0000-0000-000000000002') ->> 'ended')::boolean as ok;
reset role;

-- 4. refusals: each one must raise 'You do not have permission to end a live'
create temp table refusals (who text, refused boolean);
grant all on refusals to authenticated, anon;
do $$
declare
  c record;
  v_refused boolean;
begin
  for c in
    select * from (values
      ('Master with monitor_lives off', 'e6000003-0000-0000-0000-000000000003'),
      ('Master with no grant (the default)', 'e6000008-0000-0000-0000-000000000008'),
      ('Global Admin without the grant', 'e6000004-0000-0000-0000-000000000004'),
      ('plain user', 'e6000006-0000-0000-0000-000000000006'),
      ('the host of the live', 'e6000007-0000-0000-0000-000000000007'),
      ('signed out', null)
    ) as t(who, uid)
  loop
    perform set_config('request.jwt.claim.sub', coalesce(c.uid, ''), false);
    v_refused := false;
    begin
      perform public.admin_end_stream('e6aaaaaa-0000-0000-0000-000000000003');
    exception when others then
      v_refused := (sqlerrm = 'You do not have permission to end a live');
    end;
    insert into refusals values (c.who, v_refused);
  end loop;
end $$;
select '4 every one of these is refused (expect 6 rows, all t)' as check, who, refused from refusals;
select '4b room three is still live (expect live)' as check, status from public.live_streams where id = 'e6aaaaaa-0000-0000-0000-000000000003';

-- 5. a Global Admin who was explicitly granted monitor_lives may (same as Watch)
set role authenticated;
select set_config('request.jwt.claim.sub', 'e6000005-0000-0000-0000-000000000005', false);
select '5 a granted Global Admin ends room three (expect ended true)' as check, (public.admin_end_stream('e6aaaaaa-0000-0000-0000-000000000003') ->> 'ended')::boolean as ok;

-- 6. an unknown live is refused; a live that was already over is not touched (its ended_at stays)
do $$ begin
  perform public.admin_end_stream('e6aaaaaa-0000-0000-0000-0000000000ff');
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'That live does not exist' then raise; end if; end $$;
select '6 an unknown live is refused (expect t)' as check, true as ok;
select '6b a live that was already over reports so (expect {"ended": false, ...})' as check, public.admin_end_stream('e6aaaaaa-0000-0000-0000-000000000004') as result;
reset role;
select '6c its ended_at did not move (expect t) and there are 3 audit rows in all (one per live actually ended)' as check,
       (select ended_at < now() - interval '25 minutes' from public.live_streams where id = 'e6aaaaaa-0000-0000-0000-000000000004') as untouched,
       (select count(*) from public.audit_logs where action = 'live.killed') as audit_rows;

-- 7. anon cannot even call it
set role anon;
do $$ begin
  perform public.admin_end_stream('e6aaaaaa-0000-0000-0000-000000000003');
  raise exception 'expected a refusal';
exception when insufficient_privilege then null; end $$;
reset role;
select '7 anon has no execute right (expect t)' as check, true as ok;
