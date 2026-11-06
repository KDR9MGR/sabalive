-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/cp_seats_rollback_test.sql
-- Proves supabase/rollbacks/20261105100000_down.sql: a host on a couple seat is moved to an ordinary seat, every couple seat is cleared, the new functions and the column are gone,
-- the old seat functions still work, a second run is harmless.
insert into auth.users (id, email) values
  ('a9000000-0000-0000-0000-000000000001', 'host9@x'), ('b9000000-0000-0000-0000-000000000002', 'guest9@x');
insert into public.live_streams (id, host_id, title, status, mode, seat_count, started_at, last_heartbeat_at, cp_seats)
values ('99999999-9999-9999-9999-999999999999', 'a9000000-0000-0000-0000-000000000001', 'cp test', 'live', 'audio', 8, now(), now(), true);
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, agora_uid, last_heartbeat_at) values
  ('99999999-9999-9999-9999-999999999999', 24, 'a9000000-0000-0000-0000-000000000001', 4000000000, now()),
  ('99999999-9999-9999-9999-999999999999', 25, 'b9000000-0000-0000-0000-000000000002', null, now());

\i supabase/rollbacks/20261105100000_down.sql

select '1 the host is back on seat 1 with the same speaking id, the guest on 25 is gone (expect 1 row, seat 1, 4000000000)' as check,
       count(*) as n, min(seat_number) as seat, min(agora_uid) as uid from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999';
select '2 the new functions are gone (expect 0)' as check, count(*) as n from pg_proc where proname in ('claim_cp_seat', 'set_cp_seats', 'set_seat_count_v2', 'cp_seat_refusal');
select '3 the column is gone (expect 0)' as check, count(*) as n from information_schema.columns where table_name = 'live_streams' and column_name = 'cp_seats';
set role authenticated;
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
select public.claim_seat('99999999-9999-9999-9999-999999999999', 3);
reset role;
select '4 the old claim_seat still works (expect 2 rows)' as check, count(*) as n from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999';
\i supabase/rollbacks/20261105100000_down.sql
select '5 a second run is harmless (expect 2 rows)' as check, count(*) as n from public.live_stream_seats where live_stream_id = '99999999-9999-9999-9999-999999999999';
