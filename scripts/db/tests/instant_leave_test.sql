-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/instant_leave_test.sql
-- Proves: leaving frees the seat and writes the notice at once; the sweep drops 75 s of silence but keeps fresh people and a live host's seat.
insert into auth.users (id, email) values
  ('e4000000-0000-0000-0000-000000000001', 'host4@x'),
  ('f4000000-0000-0000-0000-000000000002', 'guest4@x'),
  ('a5000000-0000-0000-0000-000000000003', 'lurker4@x'),
  ('b5000000-0000-0000-0000-000000000004', 'fresh4@x');
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at)
values ('44444444-4444-4444-4444-444444444444', 'e4000000-0000-0000-0000-000000000001', 'leave test', 'live', 'audio', now());
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at) values
  ('44444444-4444-4444-4444-444444444444', 1, 'e4000000-0000-0000-0000-000000000001', now() - interval '200 seconds'),
  ('44444444-4444-4444-4444-444444444444', 2, 'f4000000-0000-0000-0000-000000000002', now());
insert into public.live_stream_viewers (live_stream_id, viewer_id, joined_at, last_heartbeat_at) values
  ('44444444-4444-4444-4444-444444444444', 'f4000000-0000-0000-0000-000000000002', now(), now()),
  ('44444444-4444-4444-4444-444444444444', 'a5000000-0000-0000-0000-000000000003', now() - interval '5 minutes', now() - interval '80 seconds'),
  ('44444444-4444-4444-4444-444444444444', 'b5000000-0000-0000-0000-000000000004', now() - interval '5 minutes', now() - interval '60 seconds');

-- 1. the seated guest leaves: one call
select set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0000-000000000002', false);
select public.leave_live_stream('44444444-4444-4444-4444-444444444444');
select '1 guest left: seat freed (expect 0)' as check, count(*) as n from public.live_stream_seats where occupant_id = 'f4000000-0000-0000-0000-000000000002';
select '1 guest left: viewer row closed (expect 1)' as check, count(*) as n from public.live_stream_viewers where viewer_id = 'f4000000-0000-0000-0000-000000000002' and left_at is not null;
select '1 guest left: one "left" notice (expect 1)' as check, count(*) as n from public.live_chat_messages where sender_id = 'f4000000-0000-0000-0000-000000000002' and body = 'left the live stream';
select public.leave_live_stream('44444444-4444-4444-4444-444444444444');   -- a second call is harmless
select '1b second call writes no second notice (expect 1)' as check, count(*) as n from public.live_chat_messages where sender_id = 'f4000000-0000-0000-0000-000000000002' and body = 'left the live stream';

-- 2. the sweep
select set_config('request.jwt.claim.sub', '', false);
select public.finalize_stale_presence();
select '2 viewer silent 80 s is gone (expect t)' as check, left_at is not null as ok from public.live_stream_viewers where viewer_id = 'a5000000-0000-0000-0000-000000000003';
select '2 viewer silent 60 s stays (expect t)' as check, left_at is null as ok from public.live_stream_viewers where viewer_id = 'b5000000-0000-0000-0000-000000000004';
select '2 a live host''s own seat survives a stale seat heartbeat (expect 1)' as check, count(*) as n from public.live_stream_seats where occupant_id = 'e4000000-0000-0000-0000-000000000001';
select '2 index exists (expect 1)' as check, count(*) as n from pg_indexes where indexname = 'live_stream_viewers_open_hb_idx';
