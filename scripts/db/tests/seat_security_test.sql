-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/seat_security_test.sql
-- Proves (20261023120000_seat_security): a client cannot write seat / viewer rows itself, claim_seat refuses a seat that does not exist,
-- lowering the seat count vacates the seats beyond it, the old out-of-range sweep works, and the token log is Super Admin only.
insert into auth.users (id, email) values
  ('a8000000-0000-0000-0000-000000000001', 'host8@x'),
  ('b8000000-0000-0000-0000-000000000002', 'guest8@x'),
  ('c8000000-0000-0000-0000-000000000003', 'guest8b@x'),
  ('d8000000-0000-0000-0000-000000000004', 'super8@x');
insert into public.staff_roles (user_id, role) values ('d8000000-0000-0000-0000-000000000004', 'super_admin');
insert into public.live_streams (id, host_id, title, status, mode, seat_count, started_at, last_heartbeat_at)
values ('88888888-8888-8888-8888-888888888888', 'a8000000-0000-0000-0000-000000000001', 'seat test', 'live', 'audio', 8, now(), now());

-- 1. a client cannot write a seat row itself
set role authenticated;
select set_config('request.jwt.claim.sub', 'b8000000-0000-0000-0000-000000000002', false);
do $$ begin
  insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id)
  values ('88888888-8888-8888-8888-888888888888', 99, 'b8000000-0000-0000-0000-000000000002');
  raise exception 'expected the direct seat insert to be refused';
exception when insufficient_privilege then null; end $$;
select '1 a direct seat insert is refused (expect t)' as check, true as ok;

-- 2. a client cannot write a viewer row itself, but the join function still does (row + "joined" line)
do $$ begin
  insert into public.live_stream_viewers (live_stream_id, viewer_id)
  values ('88888888-8888-8888-8888-888888888888', 'b8000000-0000-0000-0000-000000000002');
  raise exception 'expected the direct viewer insert to be refused';
exception when insufficient_privilege then null; end $$;
select '2 a direct viewer insert is refused (expect t)' as check, true as ok;
select public.join_live_stream('88888888-8888-8888-8888-888888888888');
reset role;
select '2 join_live_stream still writes the viewer row and the joined line (expect 1, 1)' as check,
       (select count(*) from public.live_stream_viewers where viewer_id = 'b8000000-0000-0000-0000-000000000002') as viewers,
       (select count(*) from public.live_chat_messages where sender_id = 'b8000000-0000-0000-0000-000000000002' and body = 'joined the live stream') as lines;

-- 3. claim_seat: a real seat works, one that does not exist is refused
set role authenticated;
select public.claim_seat('88888888-8888-8888-8888-888888888888', 2);
do $$ begin
  perform public.claim_seat('88888888-8888-8888-8888-888888888888', 9);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'That seat does not exist' then raise; end if; end $$;
do $$ begin
  perform public.claim_seat('88888888-8888-8888-8888-888888888888', 0);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'That seat does not exist' then raise; end if; end $$;
reset role;
select '3 seat 2 is taken, seats 9 and 0 are refused (expect 1 seat row, seat 2)' as check,
       count(*) as n, min(seat_number) as seat from public.live_stream_seats where live_stream_id = '88888888-8888-8888-8888-888888888888';

-- 4. lowering the seat count vacates the seats beyond it, keeps the ones inside
set role authenticated;
select set_config('request.jwt.claim.sub', 'c8000000-0000-0000-0000-000000000003', false);
select public.claim_seat('88888888-8888-8888-8888-888888888888', 6);
select set_config('request.jwt.claim.sub', 'a8000000-0000-0000-0000-000000000001', false);
select public.set_seat_count('88888888-8888-8888-8888-888888888888', 4);
reset role;
select '4 after the host lowers the count to 4, seat 6 is vacated and seat 2 stays (expect 1 row, seat 2)' as check,
       count(*) as n, min(seat_number) as seat from public.live_stream_seats where live_stream_id = '88888888-8888-8888-8888-888888888888';

-- 5. the one-time sweep statement removes an out-of-range audio seat and leaves a valid one
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id)
values ('88888888-8888-8888-8888-888888888888', 7, 'c8000000-0000-0000-0000-000000000003');
delete from public.live_stream_seats k using public.live_streams s
 where s.id = k.live_stream_id and s.mode = 'audio' and (k.seat_number < 1 or k.seat_number > s.seat_count);
select '5 the sweep leaves only the valid seat (expect 1, seat 2)' as check, count(*) as n, min(seat_number) as seat
  from public.live_stream_seats where live_stream_id = '88888888-8888-8888-8888-888888888888';

-- 6. the token log: the service role writes, a normal user sees nothing, Super Admin sees it
insert into public.agora_token_log (user_id, channel, outcome, reason) values
  ('b8000000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888888', 'refused', 'not host, no usable seat');
set role authenticated;
select set_config('request.jwt.claim.sub', 'b8000000-0000-0000-0000-000000000002', false);
select '6 a normal user reads 0 log rows (expect 0)' as check, count(*) as n from public.agora_token_log;
select set_config('request.jwt.claim.sub', 'd8000000-0000-0000-0000-000000000004', false);
select '6 Super Admin reads the row (expect 1)' as check, count(*) as n from public.agora_token_log;
do $$ begin
  insert into public.agora_token_log (user_id, channel, outcome) values ('b8000000-0000-0000-0000-000000000002', 'x', 'granted');
  raise exception 'expected a client write to the log to be refused';
exception when insufficient_privilege then null; end $$;
select '6 nobody can write the log from a client (expect t)' as check, true as ok;
reset role;
