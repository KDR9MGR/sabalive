-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/audio_seat_requests_switch_test.sql
-- Proves migration 20261021110000: with the panel switch `audio_seat_requests` OFF (the default) a viewer's seat request seats them at once on the first free
-- unlocked seat and the host cannot turn "ask before someone sits" on; with the switch ON the old behaviour is unchanged (a room that asks, or a battle,
-- makes a pending request); video rooms and the usual refusals are untouched. Every line prints "<what> (expect X)" and the result.

create or replace function pg_temp.raises(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'NOT raised';
exception when others then
  return 'raised: ' || sqlerrm;
end;
$$;

-- H host of audio room SA (5 seats; host on seat 1), V1..V5 viewers, G a ghost, B a viewer banned from seats, X host of a video room
insert into auth.users (id, email) values
  ('a1000001-0000-0000-0000-000000000001', 'h@x'), ('a2000001-0000-0000-0000-000000000001', 'v1@x'), ('a2000002-0000-0000-0000-000000000001', 'v2@x'),
  ('a2000003-0000-0000-0000-000000000001', 'v3@x'), ('a2000004-0000-0000-0000-000000000001', 'v4@x'), ('a2000005-0000-0000-0000-000000000001', 'v5@x'),
  ('a3000001-0000-0000-0000-000000000001', 'g@x'), ('a3000002-0000-0000-0000-000000000001', 'b@x'), ('b1000001-0000-0000-0000-000000000001', 'x@x');
update public.profiles set is_ghost = true where id = 'a3000001-0000-0000-0000-000000000001';

insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at) values
  ('d1000000-0000-0000-0000-000000000001', 'a1000001-0000-0000-0000-000000000001', 'audio room', 'live', 'audio', now()),
  ('e1000000-0000-0000-0000-000000000001', 'b1000001-0000-0000-0000-000000000001', 'video room', 'live', 'video', now());
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at)
  values ('d1000000-0000-0000-0000-000000000001', 1, 'a1000001-0000-0000-0000-000000000001', now());
insert into public.live_stream_seat_bans (live_stream_id, banned_id, banned_by) values ('d1000000-0000-0000-0000-000000000001', 'a3000002-0000-0000-0000-000000000001', 'a1000001-0000-0000-0000-000000000001');
update public.live_streams set locked_seats = '{3}' where id = 'd1000000-0000-0000-0000-000000000001';

select '1 the switch is OFF by default (expect false)' as check, public.audio_seat_requests_on() as on;
select '1 the helper is not callable by an app user (expect 0)' as check, count(*) as n from information_schema.routine_privileges
  where routine_schema = 'public' and routine_name = 'audio_seat_requests_on' and grantee in ('anon', 'authenticated', 'public');

-- ---------------------------------------------------------------------------------------------- switch OFF: seated at once
select set_config('request.jwt.claim.sub', 'a2000001-0000-0000-0000-000000000001', false);
select '2 V1 asks: an approved record comes back (expect approved)' as check, status from public.request_seat_v2('d1000000-0000-0000-0000-000000000001');
select '2 and V1 sits on the first free seat, 2 (host has 1) (expect 2)' as check, seat_number from public.live_stream_seats
  where live_stream_id = 'd1000000-0000-0000-0000-000000000001' and occupant_id = 'a2000001-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub', 'a2000002-0000-0000-0000-000000000001', false);
select '2 V2 asks: seat 3 is locked, so seat 4 (expect 4)' as check, 0 as dummy from public.request_seat_v2('d1000000-0000-0000-0000-000000000001');
select '2 V2 is on seat 4 (expect 4)' as check, seat_number from public.live_stream_seats where occupant_id = 'a2000002-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub', 'a2000003-0000-0000-0000-000000000001', false);
select '2 V3 asks: seat 5 (expect 5)' as check, 0 as dummy from public.request_seat_v2('d1000000-0000-0000-0000-000000000001');
select '2 V3 is on seat 5 (expect 5)' as check, seat_number from public.live_stream_seats where occupant_id = 'a2000003-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub', 'a2000004-0000-0000-0000-000000000001', false);
select '2 V4 asks: no free seat is left (expect raised)' as check, pg_temp.raises($$select public.request_seat_v2('d1000000-0000-0000-0000-000000000001')$$) as result;
select '2 nothing was left pending (expect 0)' as check, count(*) as n from public.pk_seat_requests where status = 'pending';
select '2 the answered records are kept as approved (expect 3)' as check, count(*) as n from public.pk_seat_requests where status = 'approved';

-- the usual refusals still apply
select set_config('request.jwt.claim.sub', 'a2000001-0000-0000-0000-000000000001', false);
select '3 already on a seat (expect raised)' as check, pg_temp.raises($$select public.request_seat_v2('d1000000-0000-0000-0000-000000000001')$$) as result;
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select '3 the host cannot request (expect raised)' as check, pg_temp.raises($$select public.request_seat_v2('d1000000-0000-0000-0000-000000000001')$$) as result;
select set_config('request.jwt.claim.sub', 'a3000001-0000-0000-0000-000000000001', false);
select '3 a ghost cannot (expect raised)' as check, pg_temp.raises($$select public.request_seat_v2('d1000000-0000-0000-0000-000000000001')$$) as result;
select set_config('request.jwt.claim.sub', 'a3000002-0000-0000-0000-000000000001', false);
select '3 someone banned from the seats cannot (expect raised)' as check, pg_temp.raises($$select public.request_seat_v2('d1000000-0000-0000-0000-000000000001')$$) as result;
select set_config('request.jwt.claim.sub', 'a2000005-0000-0000-0000-000000000001', false);
select '3 a VIDEO room is not an audio room (expect raised)' as check, pg_temp.raises($$select public.request_seat_v2('e1000000-0000-0000-0000-000000000001')$$) as result;
select '3 a room that is not there (expect raised)' as check, pg_temp.raises($$select public.request_seat_v2('99999999-0000-0000-0000-000000000001')$$) as result;

-- the host's "ask before someone sits"
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select '4 the host cannot switch asking ON while the panel has it off (expect raised)' as check, pg_temp.raises($$select public.set_seat_requests_v2('d1000000-0000-0000-0000-000000000001', true)$$) as result;
select '4 switching it OFF is always allowed (expect NOT raised)' as check, pg_temp.raises($$select public.set_seat_requests_v2('d1000000-0000-0000-0000-000000000001', false)$$) as result;
select '4 a null is refused (expect raised)' as check, pg_temp.raises($$select public.set_seat_requests_v2('d1000000-0000-0000-0000-000000000001', null)$$) as result;
select set_config('request.jwt.claim.sub', 'a2000001-0000-0000-0000-000000000001', false);
select '4 someone who is not the host cannot touch it (expect raised)' as check, pg_temp.raises($$select public.set_seat_requests_v2('d1000000-0000-0000-0000-000000000001', false)$$) as result;

-- a room whose host's app had already turned asking on before the switch existed still seats people at once
update public.live_streams set seat_requests = true where id = 'd1000000-0000-0000-0000-000000000001';
delete from public.live_stream_seats where occupant_id = 'a2000003-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub', 'a2000004-0000-0000-0000-000000000001', false);
select '5 an old "asks" room with the switch off still seats V4 at once (expect approved)' as check, status from public.request_seat_v2('d1000000-0000-0000-0000-000000000001');
update public.live_streams set seat_requests = false where id = 'd1000000-0000-0000-0000-000000000001';
delete from public.live_stream_seats where occupant_id = 'a2000004-0000-0000-0000-000000000001';

-- ----------------------------------------------------------------------------------------------- switch ON: as before
set session_replication_role = replica; -- the panel changes this flag as a Super Admin; the test skips that guard
update public.app_config set feature_flags = coalesce(feature_flags, '{}'::jsonb) || '{"audio_seat_requests": true}'::jsonb;
reset session_replication_role;
select '6 the switch is ON (expect true)' as check, public.audio_seat_requests_on() as on;
select set_config('request.jwt.claim.sub', 'a2000004-0000-0000-0000-000000000001', false);
select '6 a room that does not ask and has no battle refuses a request (expect raised)' as check, pg_temp.raises($$select public.request_seat_v2('d1000000-0000-0000-0000-000000000001')$$) as result;
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select '6 the host can switch asking ON (expect NOT raised)' as check, pg_temp.raises($$select public.set_seat_requests_v2('d1000000-0000-0000-0000-000000000001', true)$$) as result;
select set_config('request.jwt.claim.sub', 'a2000004-0000-0000-0000-000000000001', false);
select '6 now a request is PENDING and the viewer does not sit (expect pending, 0)' as check, status,
  (select count(*) from public.live_stream_seats where occupant_id = 'a2000004-0000-0000-0000-000000000001') as seats from public.request_seat_v2('d1000000-0000-0000-0000-000000000001');
create temp table first_ask as select id from public.request_seat_v2('d1000000-0000-0000-0000-000000000001');
select '6 asking twice returns the same pending request (expect true, 1)' as check,
  (select id from public.request_seat_v2('d1000000-0000-0000-0000-000000000001')) = (select id from first_ask) as same_request,
  (select count(*) from public.pk_seat_requests where requester_id = 'a2000004-0000-0000-0000-000000000001' and status = 'pending') as pending;

-- a flag that is not the boolean true is OFF
set session_replication_role = replica;
update public.app_config set feature_flags = coalesce(feature_flags, '{}'::jsonb) || '{"audio_seat_requests": "yes"}'::jsonb;
reset session_replication_role;
select '7 the text "yes" is not true (expect false)' as check, public.audio_seat_requests_on() as on;
set session_replication_role = replica;
update public.app_config set feature_flags = coalesce(feature_flags, '{}'::jsonb) - 'audio_seat_requests';
reset session_replication_role;
select '7 removing the flag turns it off (expect false)' as check, public.audio_seat_requests_on() as on;
select '8 the other switches are untouched (expect no audio_seat_requests key)' as check, feature_flags ? 'audio_seat_requests' as has_key from public.app_config;
