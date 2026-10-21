-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/audio_seat_requests_switch_rollback_test.sql
-- Proves supabase/rollbacks/20261021110000_down.sql: the helper is gone and the two functions are back to the 20261019100000 behaviour (a request is a
-- request again, whatever the switch says); a second rollback is harmless; applying the migration again works.

insert into auth.users (id, email) values ('a1000001-0000-0000-0000-000000000001', 'h@x'), ('a2000001-0000-0000-0000-000000000001', 'v1@x');
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at, seat_requests) values
  ('d1000000-0000-0000-0000-000000000001', 'a1000001-0000-0000-0000-000000000001', 'audio room', 'live', 'audio', now(), true);

\i supabase/rollbacks/20261021110000_down.sql
select '1 the helper is gone (expect 0)' as check, count(*) as n from pg_proc where proname = 'audio_seat_requests_on';
select '1 the two functions are back (expect 2)' as check, count(*) as n from pg_proc where proname in ('request_seat_v2', 'set_seat_requests_v2');
select set_config('request.jwt.claim.sub', 'a2000001-0000-0000-0000-000000000001', false);
select '2 with no switch at all a room that asks makes a PENDING request again (expect pending, 0 seats)' as check, status,
  (select count(*) from public.live_stream_seats where occupant_id = 'a2000001-0000-0000-0000-000000000001') as seats from public.request_seat_v2('d1000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select '2 and the host can switch asking on whatever the panel says (expect NOT raised)' as check,
  (select 'NOT raised') as result from (select public.set_seat_requests_v2('d1000000-0000-0000-0000-000000000001', true)) x;
\i supabase/rollbacks/20261021110000_down.sql
select '3 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'audio_seat_requests_on';
\i supabase/migrations/20261021110000_audio_seat_requests_switch.sql
select '4 re-applied: the helper is back and OFF (expect 1, false)' as check, (select count(*) from pg_proc where proname = 'audio_seat_requests_on') as helper, public.audio_seat_requests_on() as on;
