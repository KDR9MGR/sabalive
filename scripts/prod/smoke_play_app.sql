-- Replays what the live Play app does, as real users, and rolls everything back.
-- Run through scripts/prod/smoke_play_app.sh (it prints PASS/FAIL and checks nothing was left behind).
--
-- Why it is safe on production: it runs inside ONE transaction that ends in ROLLBACK, so no row,
-- Realtime event or push notification ever becomes visible. It takes brief row locks only.
-- It picks a host and an ordinary user by itself; it never uses a staff account.
--
-- It exercises the calls the Play build depends on: go live, heartbeat, join, chat, seats (with the
-- large Agora ids that used to fail), wallet read, leave, and the old app's way of ending a live.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;

create temp table who as
select
  (select h.profile_id from public.host_profiles h
     join public.profiles p on p.id = h.profile_id
    where p.is_ghost = false and p.status = 'active'
      -- the live_streams insert rule needs a host with active go-live access
      and exists (select 1 from public.host_grants g
                   where g.profile_id = h.profile_id and g.status = 'active'
                     and (g.expires_at is null or g.expires_at > now()))
      and not exists (select 1 from public.staff_roles s where s.user_id = h.profile_id)
    order by p.created_at desc limit 1) as host_id,
  (select p.id from public.profiles p
    where p.is_host = false and p.is_ghost = false and p.status = 'active'
      and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
    order by p.created_at desc limit 1) as viewer_id;
grant select on who to public;

set local role authenticated;

do $$
declare
  v_host uuid := (select host_id from who);
  v_view uuid := (select viewer_id from who);
  sid uuid;
  w int;
begin
  if v_host is null or v_view is null then
    insert into res(step, ok, info) values ('0 pick test users', false, 'no host or no ordinary user found');
    return;
  end if;

  -- as the host
  perform set_config('request.jwt.claim.sub', v_host::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_host), true);

  begin
    insert into public.live_streams (host_id, title, category, mode)
    values (v_host, 'zz-smoke-test (rolled back)', 'Chat', 'audio') returning id into sid;
    insert into res(step, ok) values ('1 host goes live', true);
  exception when others then
    insert into res(step, ok, info) values ('1 host goes live', false, sqlerrm);
    return;
  end;
  begin perform public.heartbeat_stream(sid); insert into res(step, ok) values ('2 host heartbeat', true);
  exception when others then insert into res(step, ok, info) values ('2 host heartbeat', false, sqlerrm); end;
  begin perform public.set_host_agora_uid(sid, 4287323012); insert into res(step, ok) values ('3 host saves a large Agora id', true);
  exception when others then insert into res(step, ok, info) values ('3 host saves a large Agora id', false, sqlerrm); end;

  -- as an ordinary viewer
  perform set_config('request.jwt.claim.sub', v_view::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_view), true);

  begin perform public.join_live_stream(sid); insert into res(step, ok) values ('4 viewer joins', true);
  exception when others then insert into res(step, ok, info) values ('4 viewer joins', false, sqlerrm); end;
  begin perform public.heartbeat_viewer(sid); insert into res(step, ok) values ('5 viewer heartbeat', true);
  exception when others then insert into res(step, ok, info) values ('5 viewer heartbeat', false, sqlerrm); end;
  begin
    insert into public.live_chat_messages (live_stream_id, sender_id, body, kind) values (sid, v_view, 'hello', 'text');
    insert into res(step, ok) values ('6 viewer sends a chat message', true);
  exception when others then insert into res(step, ok, info) values ('6 viewer sends a chat message', false, sqlerrm); end;
  begin perform public.claim_seat(sid, 2); insert into res(step, ok) values ('7 viewer takes a seat', true);
  exception when others then insert into res(step, ok, info) values ('7 viewer takes a seat', false, sqlerrm); end;
  begin perform public.set_seat_agora_uid(sid, 3000000001); insert into res(step, ok) values ('8 seat saves a large Agora id', true);
  exception when others then insert into res(step, ok, info) values ('8 seat saves a large Agora id', false, sqlerrm); end;
  begin perform public.heartbeat_seat(sid); perform public.release_seat(sid); insert into res(step, ok) values ('9 seat heartbeat and release', true);
  exception when others then insert into res(step, ok, info) values ('9 seat heartbeat and release', false, sqlerrm); end;
  begin
    select count(*) into w from public.wallets where profile_id = v_view;
    insert into res(step, ok, info) values ('10 viewer reads their own wallet', w = 1, w || ' row(s)');
  exception when others then insert into res(step, ok, info) values ('10 viewer reads their own wallet', false, sqlerrm); end;
  begin perform public.leave_live_stream(sid); insert into res(step, ok) values ('11 viewer leaves', true);
  exception when others then insert into res(step, ok, info) values ('11 viewer leaves', false, sqlerrm); end;

  -- the host ends it the way the old app does (local time, no zone)
  perform set_config('request.jwt.claim.sub', v_host::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_host), true);
  begin
    update public.live_streams set status = 'ended', ended_at = (now() at time zone 'utc' + interval '5.5 hours') where id = sid;
    insert into res(step, ok, info)
    select '12 host ends the live (old app, local time)',
           abs(extract(epoch from (ended_at - now()))) < 5,
           'ended_at is ' || round(extract(epoch from (ended_at - now())))::text || ' s from now (should be about 0)'
      from public.live_streams where id = sid;
  exception when others then insert into res(step, ok, info) values ('12 host ends the live', false, sqlerrm); end;
end
$$;

select n, step, ok, info from res order by n;

rollback;
