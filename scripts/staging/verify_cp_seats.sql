-- Exercises 20261105100000 (CP / couple seats) on STAGING with the real roles and grants, then rolls back. Run through scripts/staging/verify_cp_seats.sh.
-- Builds its own people and two lives (audio + video); ends in ROLLBACK.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

do $$
declare
  h uuid := gen_random_uuid(); g uuid := gen_random_uuid(); g2 uuid := gen_random_uuid();
  live uuid := gen_random_uuid(); vid uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data) values
    (h, 'authenticated', 'authenticated', 'zz-smoke-cph@staging.sabalive.test', '{"name":"ZZ Host"}'),
    (g, 'authenticated', 'authenticated', 'zz-smoke-cpg@staging.sabalive.test', '{"name":"ZZ Guest"}'),
    (g2, 'authenticated', 'authenticated', 'zz-smoke-cpg2@staging.sabalive.test', '{"name":"ZZ Guest 2"}');
  insert into public.live_streams (id, host_id, title, status, mode, seat_count, last_heartbeat_at) values
    (live, h, 'zz cp seats', 'live', 'audio', 8, now()), (vid, h, 'zz cp video', 'live', 'video', 8, now());
  insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, agora_uid, last_heartbeat_at) values (live, 1, h, 3000000000, now());
  insert into ids values ('h', h::text), ('g', g::text), ('g2', g2::text), ('live', live::text), ('vid', vid::text);
end
$$;

set local role authenticated;
do $$
declare
  h uuid := (select val::uuid from ids where k = 'h');
  g uuid := (select val::uuid from ids where k = 'g');
  g2 uuid := (select val::uuid from ids where k = 'g2');
  live uuid := (select val::uuid from ids where k = 'live');
  vid uuid := (select val::uuid from ids where k = 'vid');
begin
  -- a guest cannot sit on a couple seat while they are off
  perform set_config('request.jwt.claim.sub', g::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g), true);
  begin
    perform public.claim_cp_seat(live, 25);
    insert into res(step, ok, info) values ('1 a guest cannot take seat 25 while CP seats are off', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('1 a guest cannot take seat 25 while CP seats are off', sqlerrm = 'This room has no couple seats', sqlerrm); end;
  begin
    perform public.set_cp_seats(live, true);
    insert into res(step, ok, info) values ('2 a guest cannot switch CP seats on', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('2 a guest cannot switch CP seats on', sqlerrm = 'Only the host can change the couple seats', sqlerrm); end;

  -- the host switches them on
  perform set_config('request.jwt.claim.sub', h::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', h), true);
  perform public.set_cp_seats(live, true);
  insert into res(step, ok, info) select '3 CP seats are on, the host is only on seat 24 and keeps the speaking id',
    (select cp_seats from public.live_streams where id = live)
    and (select count(*) from public.live_stream_seats where live_stream_id = live) = 1
    and (select agora_uid from public.live_stream_seats where live_stream_id = live and seat_number = 24) = 3000000000, null;
  begin
    perform public.set_cp_seats(vid, true);
    insert into res(step, ok, info) values ('4 a video room cannot have couple seats', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('4 a video room cannot have couple seats', sqlerrm = 'Couple seats are for audio rooms', sqlerrm); end;

  -- a guest sits on the right one; nobody else can take the left one or a taken right one
  perform set_config('request.jwt.claim.sub', g::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g), true);
  perform public.claim_cp_seat(live, 25);
  insert into res(step, ok, info) select '5 a guest sits on seat 25', exists (select 1 from public.live_stream_seats where live_stream_id = live and seat_number = 25 and occupant_id = g), null;
  begin
    perform public.claim_cp_seat(live, 24);
    insert into res(step, ok, info) values ('6 nobody but the host takes the left seat', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('6 nobody but the host takes the left seat', sqlerrm = 'The left couple seat is the host''s', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', g2::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g2), true);
  begin
    perform public.claim_cp_seat(live, 25);
    insert into res(step, ok, info) values ('7 a second guest cannot take the taken right seat', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('7 a second guest cannot take the taken right seat', sqlerrm = 'This seat is already taken', sqlerrm); end;
  begin
    perform public.claim_seat(live, 24);
    insert into res(step, ok, info) values ('8 the OLD claim_seat still refuses seat 24 (old apps are unaffected)', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('8 the OLD claim_seat still refuses seat 24 (old apps are unaffected)', sqlerrm = 'That seat does not exist', sqlerrm); end;

  -- lowering the seat count: v2 keeps the couple
  perform set_config('request.jwt.claim.sub', h::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', h), true);
  perform public.set_seat_count_v2(live, 4);
  insert into res(step, ok, info) select '9 seat count 4 through v2 keeps both couple seats',
    (select count(*) from public.live_stream_seats where live_stream_id = live and seat_number in (24, 25)) = 2, null;

  -- switching off
  perform public.set_cp_seats(live, false);
  insert into res(step, ok, info) select '10 CP off: the guest is off the couple seat, the host is back on seat 1 with the same speaking id',
    not (select cp_seats from public.live_streams where id = live)
    and (select count(*) from public.live_stream_seats where live_stream_id = live) = 1
    and (select seat_number from public.live_stream_seats where live_stream_id = live) = 1
    and (select agora_uid from public.live_stream_seats where live_stream_id = live) = 3000000000, null;
end
$$;
reset role;
insert into res(step, ok, info) values ('11 anon cannot call the new functions; the rule function is internal',
  not has_function_privilege('anon', 'public.claim_cp_seat(uuid,integer)', 'execute')
  and not has_function_privilege('anon', 'public.set_cp_seats(uuid,boolean)', 'execute')
  and not has_function_privilege('anon', 'public.set_seat_count_v2(uuid,integer)', 'execute')
  and has_function_privilege('authenticated', 'public.claim_cp_seat(uuid,integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.cp_seat_refusal(uuid,uuid,integer)', 'execute'), null);

select n, step, ok, info from res order by n;

rollback;
