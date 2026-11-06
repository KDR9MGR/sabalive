-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/cp_seats_test.sql
-- Proves (20261105100000_cp_seats): the host switches CP seats on and is seated on the left one in the same step (keeping their speaking id), a guest can sit on the right
-- one only while the room has CP seats, nobody but the host takes the left one, the old claim_seat still refuses seats 24 / 25, taking a CP seat gives up the guest's
-- ordinary seat, lowering the seat count keeps the couple (v2) while the old function would not, switching off clears the couple and puts the host back on an ordinary seat,
-- and every other kind of room / caller is refused. Rolled-forward state is checked with plain selects: every line says what to expect.
insert into auth.users (id, email) values
  ('a9000000-0000-0000-0000-000000000001', 'host9@x'),
  ('b9000000-0000-0000-0000-000000000002', 'guest9@x'),
  ('c9000000-0000-0000-0000-000000000003', 'guest9b@x'),
  ('d9000000-0000-0000-0000-000000000004', 'other9@x');
insert into public.live_streams (id, host_id, title, status, mode, seat_count, started_at, last_heartbeat_at) values
  ('99999999-9999-9999-9999-999999999999', 'a9000000-0000-0000-0000-000000000001', 'cp test', 'live', 'audio', 8, now(), now()),
  ('98999999-9999-9999-9999-999999999998', 'a9000000-0000-0000-0000-000000000001', 'video room', 'live', 'video', 8, now(), now());
-- the host already sits on seat 1 with a speaking id, as the app leaves them
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, agora_uid, last_heartbeat_at)
values ('99999999-9999-9999-9999-999999999999', 1, 'a9000000-0000-0000-0000-000000000001', 4000000000, now());

select '0 a new room has no CP seats (expect f)' as check, cp_seats as ok from public.live_streams where id = '99999999-9999-9999-9999-999999999999';

-- 1. before the host switches them on, nobody can sit on a couple seat
set role authenticated;
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
do $$ begin
  perform public.claim_cp_seat('99999999-9999-9999-9999-999999999999', 25);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'This room has no couple seats' then raise; end if; end $$;
select '1 a guest cannot take seat 25 while CP seats are off (expect t)' as check, true as ok;

-- 2. only the host can switch them on
do $$ begin
  perform public.set_cp_seats('99999999-9999-9999-9999-999999999999', true);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'Only the host can change the couple seats' then raise; end if; end $$;
select '2 a guest cannot switch CP seats on (expect t)' as check, true as ok;

-- 3. the host switches them on: seat 1 is left, seat 24 is taken, speaking id kept
select set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-000000000001', false);
select public.set_cp_seats('99999999-9999-9999-9999-999999999999', true);
reset role;
select '3 CP is on, the host is only on seat 24 with the same speaking id (expect t, 1 row, 24, 4000000000)' as check,
       (select cp_seats from public.live_streams where id = '99999999-9999-9999-9999-999999999999') as cp,
       (select count(*) from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999') as rows,
       (select min(seat_number) from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999') as seat,
       (select agora_uid from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999' and seat_number = 24) as uid;

-- 4. a guest sits on the right one; nobody else can take the left one; the right one cannot be taken twice
set role authenticated;
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
select public.claim_cp_seat('99999999-9999-9999-9999-999999999999', 25);
do $$ begin
  perform public.claim_cp_seat('99999999-9999-9999-9999-999999999999', 24);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'The left couple seat is the host''s' then raise; end if; end $$;
select set_config('request.jwt.claim.sub', 'c9000000-0000-0000-0000-000000000003', false);
do $$ begin
  perform public.claim_cp_seat('99999999-9999-9999-9999-999999999999', 25);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'This seat is already taken' then raise; end if; end $$;
reset role;
select '4 seat 25 is the guest''s, 24 the host''s (expect 2 rows: 24 host, 25 guest)' as check, seat_number, occupant_id
  from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999' order by seat_number;

-- 4b. the host claiming their own couple seat again (coming back to the room) is not "taken"
set role authenticated;
select set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-000000000001', false);
select public.claim_cp_seat('99999999-9999-9999-9999-999999999999', 24);
reset role;
select '4b the host re-claims seat 24 without an error and still holds it (expect 24, a9...)' as check, seat_number, occupant_id
  from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999' and seat_number = 24;

-- 5. seats that are not couple seats are refused, and the old claim_seat still refuses 24 / 25 (it was not changed)
set role authenticated;
select set_config('request.jwt.claim.sub', 'c9000000-0000-0000-0000-000000000003', false);
do $$ begin
  perform public.claim_cp_seat('99999999-9999-9999-9999-999999999999', 3);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'That seat does not exist' then raise; end if; end $$;
do $$ begin
  perform public.claim_seat('99999999-9999-9999-9999-999999999999', 24);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'That seat does not exist' then raise; end if; end $$;
select '5 seat 3 is not a couple seat, claim_seat still refuses 24 (expect t)' as check, true as ok;

-- 6. a guest on an ordinary seat who takes a couple seat gives the ordinary one up
select public.claim_seat('99999999-9999-9999-9999-999999999999', 2);
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
select public.release_seat('99999999-9999-9999-9999-999999999999');
select set_config('request.jwt.claim.sub', 'c9000000-0000-0000-0000-000000000003', false);
select public.claim_cp_seat('99999999-9999-9999-9999-999999999999', 25);
reset role;
select '6 the second guest left seat 2 for seat 25 (expect 2 rows: 24 host, 25 guest c9)' as check, seat_number, occupant_id
  from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999' order by seat_number;

-- 7. lowering the seat count: v2 keeps the couple, an ordinary guest above the count goes (the old function would take the couple with it)
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at)
values ('99999999-9999-9999-9999-999999999999', 7, 'b9000000-0000-0000-0000-000000000002', now());
set role authenticated;
select set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-000000000001', false);
select public.set_seat_count_v2('99999999-9999-9999-9999-999999999999', 4);
reset role;
select '7 v2 to 4 seats: seat 7 is gone, 24 and 25 stay (expect 24, 25)' as check, seat_number
  from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999' order by seat_number;

-- 8. switching off: the couple seat of the guest is cleared, the host is back on an ordinary seat (seat 1), speaking id kept
set role authenticated;
select public.set_cp_seats('99999999-9999-9999-9999-999999999999', false);
reset role;
select '8 CP off: f, only the host remains, on seat 1 with the same speaking id (expect f, 1, 1, 4000000000)' as check,
       (select cp_seats from public.live_streams where id = '99999999-9999-9999-9999-999999999999') as cp,
       (select count(*) from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999') as rows,
       (select min(seat_number) from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999') as seat,
       (select agora_uid from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999') as uid;

-- 9. only an audio room that is live can have couple seats
set role authenticated;
do $$ begin
  perform public.set_cp_seats('98999999-9999-9999-9999-999999999998', true);
  raise exception 'expected a refusal';
exception when others then if sqlerrm <> 'Couple seats are for audio rooms' then raise; end if; end $$;
select '9 a video room cannot have couple seats (expect t)' as check, true as ok;

-- 10. a signed-out caller can do none of it
reset role;
set role anon;
do $$ begin
  perform public.claim_cp_seat('99999999-9999-9999-9999-999999999999', 25);
  raise exception 'expected a refusal';
exception when insufficient_privilege then null; end $$;
do $$ begin
  perform public.set_cp_seats('99999999-9999-9999-9999-999999999999', true);
  raise exception 'expected a refusal';
exception when insufficient_privilege then null; end $$;
reset role;
select '10 anon cannot call the new functions (expect t)' as check, true as ok;

-- 11. the rule function is not callable by the app (only by the seat functions)
set role authenticated;
do $$ begin
  perform public.cp_seat_refusal('99999999-9999-9999-9999-999999999999', 'b9000000-0000-0000-0000-000000000002', 25);
  raise exception 'expected a refusal';
exception when insufficient_privilege then null; end $$;
reset role;
select '11 cp_seat_refusal is internal (expect t)' as check, true as ok;
