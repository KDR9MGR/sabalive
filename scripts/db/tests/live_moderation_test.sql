-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/live_moderation_test.sql
-- Room admins, kick (can come back), ban, ban text, seat tools for admins, protections, seat counts 4..25.
insert into auth.users (id, email) values
  ('a9000000-0000-0000-0000-000000000001', 'host9@x'),
  ('b9000000-0000-0000-0000-000000000002', 'admin9@x'),
  ('c9000000-0000-0000-0000-000000000003', 'viewer9@x'),
  ('d9000000-0000-0000-0000-000000000004', 'viewer9b@x'),
  ('e9000000-0000-0000-0000-000000000005', 'stranger9@x'),
  ('f9000000-0000-0000-0000-000000000006', 'admin9b@x');
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at)
values ('99999999-0000-0000-0000-000000000099', 'a9000000-0000-0000-0000-000000000001', 'mod test', 'live', 'audio', now());

-- the host makes two admins
select set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-000000000001', false);
select public.set_room_admin('b9000000-0000-0000-0000-000000000002', true);
select public.set_room_admin('f9000000-0000-0000-0000-000000000006', true);
select '1 two admins (expect 2)' as check, count(*) as n from public.live_room_admins where host_id = 'a9000000-0000-0000-0000-000000000001';
select '1 admin is a moderator, stranger is not (expect t, f)' as check,
       public.is_room_moderator('99999999-0000-0000-0000-000000000099', 'b9000000-0000-0000-0000-000000000002') as admin_ok,
       public.is_room_moderator('99999999-0000-0000-0000-000000000099', 'e9000000-0000-0000-0000-000000000005') as stranger;
-- a host can't add themself; the limit is 5
do $$ begin perform public.set_room_admin('a9000000-0000-0000-0000-000000000001', true); raise exception 'expected refusal';
exception when others then if sqlerrm <> 'You are already the host' then raise; end if; end $$;
insert into auth.users (id, email) select (g || '1000000-0000-0000-0000-000000000000')::uuid, 'x' || g || '@x' from generate_series(1, 4) g;
select public.set_room_admin((g || '1000000-0000-0000-0000-000000000000')::uuid, true) from generate_series(1, 3) g;
do $$ begin perform public.set_room_admin('41000000-0000-0000-0000-000000000000', true); raise exception 'expected refusal';
exception when others then if sqlerrm <> 'You can have up to 5 room admins' then raise; end if; end $$;
select '1 the sixth admin is refused (expect 5 admins)' as check, count(*) as n from public.live_room_admins where host_id = 'a9000000-0000-0000-0000-000000000001';
select public.set_room_admin((g || '1000000-0000-0000-0000-000000000000')::uuid, false) from generate_series(1, 3) g;
select '1 removing an admin works (expect 2 left)' as check, count(*) as n from public.live_room_admins where host_id = 'a9000000-0000-0000-0000-000000000001';

-- viewers join; the admin kicks viewer c: removed, but can come back
select set_config('request.jwt.claim.sub', 'c9000000-0000-0000-0000-000000000003', false);
select public.join_live_stream('99999999-0000-0000-0000-000000000099');
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
select public.kick_viewer('99999999-0000-0000-0000-000000000099', 'c9000000-0000-0000-0000-000000000003');
select '2 kicked viewer is out of the room (expect 1 closed row)' as check, count(*) as n from public.live_stream_viewers where viewer_id = 'c9000000-0000-0000-0000-000000000003' and left_at is not null;
select '2 the kick left a signal for that person (expect 1)' as check, count(*) as n from public.live_stream_kicks where user_id = 'c9000000-0000-0000-0000-000000000003';
select set_config('request.jwt.claim.sub', 'c9000000-0000-0000-0000-000000000003', false);
select public.join_live_stream('99999999-0000-0000-0000-000000000099');
select '2 a kicked person can come back (expect 1 open row)' as check, count(*) as n from public.live_stream_viewers where viewer_id = 'c9000000-0000-0000-0000-000000000003' and left_at is null;

-- ban (keeps them out of this live): viewer d
select set_config('request.jwt.claim.sub', 'd9000000-0000-0000-0000-000000000004', false);
select public.join_live_stream('99999999-0000-0000-0000-000000000099');
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
select public.block_viewer('99999999-0000-0000-0000-000000000099', 'd9000000-0000-0000-0000-000000000004');
select set_config('request.jwt.claim.sub', 'd9000000-0000-0000-0000-000000000004', false);
do $$ begin perform public.join_live_stream('99999999-0000-0000-0000-000000000099'); raise exception 'expected the join to be refused';
exception when others then if sqlerrm = 'expected the join to be refused' then raise; end if; end $$;
select '3 a banned person cannot rejoin (expect t)' as check, true as ok;

-- protections
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
do $$ begin perform public.kick_viewer('99999999-0000-0000-0000-000000000099', 'a9000000-0000-0000-0000-000000000001'); raise exception 'expected refusal';
exception when others then if sqlerrm <> 'You can''t do that to the host' then raise; end if; end $$;
do $$ begin perform public.block_viewer('99999999-0000-0000-0000-000000000099', 'f9000000-0000-0000-0000-000000000006'); raise exception 'expected refusal';
exception when others then if sqlerrm <> 'Only the host can do that to an admin' then raise; end if; end $$;
select '4 an admin cannot act on the host or another admin (expect t)' as check, true as ok;
select set_config('request.jwt.claim.sub', 'e9000000-0000-0000-0000-000000000005', false);
do $$ begin perform public.kick_viewer('99999999-0000-0000-0000-000000000099', 'c9000000-0000-0000-0000-000000000003'); raise exception 'expected refusal';
exception when others then if sqlerrm <> 'Only the host or a room admin can do this' then raise; end if; end $$;
do $$ begin perform public.set_seat_lock('99999999-0000-0000-0000-000000000099', 3, true); raise exception 'expected refusal';
exception when others then if sqlerrm <> 'Only the host or a room admin can do this' then raise; end if; end $$;
select '4 a stranger can do nothing (expect t)' as check, true as ok;
select set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-000000000001', false);
select public.block_viewer('99999999-0000-0000-0000-000000000099', 'f9000000-0000-0000-0000-000000000006');
select '4 the host can act on an admin (expect 1 ban row for the admin)' as check, count(*) as n from public.live_stream_viewer_bans where user_id = 'f9000000-0000-0000-0000-000000000006';

-- ban text: the person stays but cannot send text; system lines and a lifted ban work
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
select public.mute_chat('99999999-0000-0000-0000-000000000099', 'c9000000-0000-0000-0000-000000000003', true);
do $$ begin
  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
    values ('99999999-0000-0000-0000-000000000099', 'c9000000-0000-0000-0000-000000000003', 'hello', 'text');
  raise exception 'expected the text to be refused';
exception when others then if sqlerrm = 'expected the text to be refused' then raise; end if; end $$;
select '5 a text-banned person cannot send text (expect t)' as check, true as ok;
insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
  values ('99999999-0000-0000-0000-000000000099', 'c9000000-0000-0000-0000-000000000003', 'left the live stream', 'system');
select '5 system lines still go through (expect 1)' as check, count(*) as n from public.live_chat_messages where kind = 'system' and body = 'left the live stream' and sender_id = 'c9000000-0000-0000-0000-000000000003';
select public.mute_chat('99999999-0000-0000-0000-000000000099', 'c9000000-0000-0000-0000-000000000003', false);
insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
  values ('99999999-0000-0000-0000-000000000099', 'c9000000-0000-0000-0000-000000000003', 'hello again', 'text');
select '5 after the ban is lifted text works (expect 1)' as check, count(*) as n from public.live_chat_messages where kind = 'text' and sender_id = 'c9000000-0000-0000-0000-000000000003';

-- seat tools for an admin
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at) values
  ('99999999-0000-0000-0000-000000000099', 1, 'a9000000-0000-0000-0000-000000000001', now()),
  ('99999999-0000-0000-0000-000000000099', 2, 'c9000000-0000-0000-0000-000000000003', now());
select public.set_seat_lock('99999999-0000-0000-0000-000000000099', 6, true);
select '6 an admin can lock a seat (expect {6})' as check, locked_seats as locked from public.live_streams where id = '99999999-0000-0000-0000-000000000099';
select public.host_set_seat_mute('99999999-0000-0000-0000-000000000099', 2, true);
select '6 an admin can mute a guest seat (expect t)' as check, is_muted as ok from public.live_stream_seats where seat_number = 2;
do $$ begin perform public.host_set_seat_mute('99999999-0000-0000-0000-000000000099', 1, true); raise exception 'expected refusal';
exception when others then if sqlerrm <> 'You can''t do that to the host' then raise; end if; end $$;
select '6 but not the host''s seat (expect t)' as check, true as ok;
select public.kick_seat_occupant('99999999-0000-0000-0000-000000000099', 2);
select '6 an admin can remove a guest from a seat (expect 1 seat left)' as check, count(*) as n from public.live_stream_seats where live_stream_id = '99999999-0000-0000-0000-000000000099';

-- seat counts: 4 and steps of 4, and the old multiples of 5 still work
select set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-000000000001', false);
select public.set_seat_count('99999999-0000-0000-0000-000000000099', 4);
select '7 four seats is allowed (expect 4)' as check, seat_count as n from public.live_streams where id = '99999999-0000-0000-0000-000000000099';
select public.set_seat_count('99999999-0000-0000-0000-000000000099', 16);
select public.set_seat_count('99999999-0000-0000-0000-000000000099', 10);
select '7 16 and the old multiples of 5 still work (expect 10)' as check, seat_count as n from public.live_streams where id = '99999999-0000-0000-0000-000000000099';
do $$ begin perform public.set_seat_count('99999999-0000-0000-0000-000000000099', 3); raise exception 'expected refusal';
exception when others then if sqlerrm not like 'Seat count must be%' then raise; end if; end $$;
select '7 fewer than 4 is refused (expect t)' as check, true as ok;
