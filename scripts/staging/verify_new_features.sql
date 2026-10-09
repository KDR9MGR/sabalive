-- Exercises the 20261009* features on STAGING as real (fake) users with the real grants, then rolls everything back.
-- Run through scripts/staging/verify_new_features.sh. Safe: one transaction that ends in ROLLBACK.
--
-- It checks: send to All (balance, rows, one "to All" line, who is skipped), instant leave (seat freed + notice),
-- the effect speed / sound columns, the Lucky Box pull back (Master only, once), app_config in Realtime, and that
-- the new functions are executable by signed-in users and NOT by anonymous callers.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;

create temp table who as
select
  (select h.profile_id from public.host_profiles h
     join public.profiles p on p.id = h.profile_id
    where p.is_ghost = false and p.status = 'active'
      and exists (select 1 from public.host_grants g
                   where g.profile_id = h.profile_id and g.status = 'active'
                     and (g.expires_at is null or g.expires_at > now()))
      and not exists (select 1 from public.staff_roles s where s.user_id = h.profile_id)
    order by p.created_at desc limit 1) as host_id,
  (select p.id from public.profiles p
    where p.is_host = false and p.is_ghost = false and p.status = 'active'
      and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
    order by p.created_at desc limit 1) as viewer_id,
  (select p.id from public.profiles p
    where p.is_ghost = false and p.status = 'active'
      and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
      and p.id not in (select h.profile_id from public.host_profiles h)
    order by p.created_at asc limit 1) as guest_id,
  (select s.user_id from public.staff_roles s where s.role = 'admin' order by s.created_at limit 1) as master_id;
grant select on who to public;

create temp table ids (k text primary key, v uuid);
grant all on ids to public;

-- setup as the owner: a live that started 2 hours ago (so the Lucky Box is due), the gift to send, funds
do $$
declare
  v_host uuid := (select host_id from who);
  v_view uuid := (select viewer_id from who);
  sid uuid;
  rid uuid;
  gid uuid;
begin
  if v_host is null or v_view is null then
    insert into res(step, ok, info) values ('setup: a host and a viewer exist on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  insert into public.live_streams (host_id, title, status, mode, started_at, last_heartbeat_at)
    values (v_host, 'zz-smoke-test new features', 'live', 'video', now() - interval '2 hours', now())
    returning id into sid;
  insert into ids values ('stream', sid);
  select id into gid from public.gifts where status = 'active' order by price_coins limit 1;
  insert into ids values ('gift', gid);
  insert into public.live_streams (host_id, title, status, mode, last_heartbeat_at)
    values (v_host, 'zz-smoke-test audio room', 'live', 'audio', now())
    returning id into rid;
  insert into ids values ('room', rid);
  -- make sure the viewer can afford a few gifts
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (v_view, 'purchase', 'coins', 5000, 'coin_purchases', 'zz-smoke-test funds');
  -- a second person on a seat so "to All" has the host AND a guest
  if (select guest_id from who) is not null then
    insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at)
      values (sid, 2, (select guest_id from who), now());
  end if;
end
$$;

set local role authenticated;

do $$
declare
  v_host uuid := (select host_id from who);
  v_view uuid := (select viewer_id from who);
  v_guest uuid := (select guest_id from who);
  sid uuid := (select v from ids where k = 'stream');
  rid uuid;
  gid uuid := (select v from ids where k = 'gift');
  price int;
  before_coins bigint;
  after_coins bigint;
  n int;
  expected int;
begin
  if sid is null then return; end if;
  select price_coins into price from public.gifts where id = gid;

  perform set_config('request.jwt.claim.sub', v_view::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_view), true);

  -- 1. send to All
  select coins into before_coins from public.wallets where profile_id = v_view;
  expected := 1 + case when v_guest is not null and v_guest <> v_host and v_guest <> v_view then 1 else 0 end;
  begin
    n := public.send_gift_to_all(gid, sid);
    select coins into after_coins from public.wallets where profile_id = v_view;
    insert into res(step, ok, info) values
      ('1 send to All answers with the number of people', n = expected, 'got ' || n || ', expected ' || expected);
    insert into res(step, ok, info) values
      ('1 the sender paid price x people', before_coins - after_coins = price::bigint * n,
       'paid ' || (before_coins - after_coins) || ' for ' || n || ' x ' || price);
    insert into res(step, ok, info)
      select '1 ONE chat line "to All" carrying the gift', count(*) = 1 and bool_and(to_all) and bool_and(gift_id = gid) and bool_and(body like '% to All'),
             'lines: ' || count(*)
        from public.live_chat_messages where live_stream_id = sid and kind = 'gift';
  exception when others then
    insert into res(step, ok, info) values ('1 send to All', false, sqlerrm);
  end;

  -- 2. instant leave (an audio room, where a seat is claimed without the host's approval): take a seat,
  --    leave, and the seat is gone at once with the "left" notice written
  begin
    rid := (select v from ids where k = 'room');
    perform public.join_live_stream(rid);
    perform public.claim_seat(rid, 5);
    perform public.leave_live_stream(rid);
    insert into res(step, ok, info)
      select '2 leaving frees my seat at once', count(*) = 0, 'seats still mine: ' || count(*)
        from public.live_stream_seats where live_stream_id = rid and occupant_id = v_view;
    insert into res(step, ok, info)
      select '2 the "left" notice is written at once', count(*) = 1, 'notices: ' || count(*)
        from public.live_chat_messages where live_stream_id = rid and sender_id = v_view and body = 'left the live stream';
  exception when others then
    insert into res(step, ok, info) values ('2 instant leave', false, sqlerrm);
  end;

  -- 3. the effect columns are readable by a signed-in user
  begin
    perform play_speed, sound_url from public.gifts limit 1;
    perform play_speed, sound_url from public.store_items limit 1;
    insert into res(step, ok) values ('3 play_speed / sound_url readable on gifts and store_items', true);
  exception when others then
    insert into res(step, ok, info) values ('3 play_speed / sound_url readable', false, sqlerrm);
  end;
end
$$;

-- 4. Lucky Box: the cron pays the host, a normal user cannot pull it back, the Master can, once
reset role;
do $$
declare
  v_host uuid := (select host_id from who);
  v_view uuid := (select viewer_id from who);
  v_master uuid := (select master_id from who);
  sid uuid := (select v from ids where k = 'stream');
  win uuid;
begin
  if sid is null then return; end if;
  perform public.grant_lucky_box_rewards();
  select id into win from public.wallet_ledger where note = 'lucky_box' and reference_id = sid;
  insert into res(step, ok, info) values ('4 the Lucky Box paid the host', win is not null, null);
  if win is null then return; end if;
  insert into ids values ('win', win);
  if v_master is null then
    insert into res(step, ok, info) values ('4 a Master account exists to test the pull back', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
end
$$;

set local role authenticated;
do $$
declare
  v_view uuid := (select viewer_id from who);
  v_master uuid := (select master_id from who);
  win uuid := (select v from ids where k = 'win');
  before_d bigint;
  after_d bigint;
begin
  if win is null or v_master is null then return; end if;
  -- an ordinary user is refused
  perform set_config('request.jwt.claim.sub', v_view::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_view), true);
  begin
    perform public.lucky_box_pull_back(win);
    insert into res(step, ok, info) values ('4 an ordinary user cannot pull back a reward', false, 'it worked');
  exception when others then
    insert into res(step, ok, info) values ('4 an ordinary user cannot pull back a reward', sqlerrm like 'Only a Master%', sqlerrm);
  end;
  -- the Master can, once
  perform set_config('request.jwt.claim.sub', v_master::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_master), true);
  select diamonds into before_d from public.wallets where profile_id = (select host_id from who);
  begin
    perform public.lucky_box_pull_back(win);
    select diamonds into after_d from public.wallets where profile_id = (select host_id from who);
    insert into res(step, ok, info) values ('4 the Master pulls the reward back', before_d - after_d > 0, 'host diamonds ' || before_d || ' -> ' || after_d);
  exception when others then
    insert into res(step, ok, info) values ('4 the Master pulls the reward back', false, sqlerrm);
  end;
  begin
    perform public.lucky_box_pull_back(win);
    insert into res(step, ok, info) values ('4 a second pull back is refused', false, 'it worked');
  exception when others then
    insert into res(step, ok, info) values ('4 a second pull back is refused', sqlerrm = 'This reward has already been pulled back', sqlerrm);
  end;
end
$$;

-- 5. anonymous callers cannot use the new money functions
set local role anon;
do $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  begin
    perform public.send_gift_to_all(gen_random_uuid(), gen_random_uuid());
    insert into res(step, ok, info) values ('5 anonymous callers cannot send to All', false, 'it ran');
  exception when insufficient_privilege then
    insert into res(step, ok, info) values ('5 anonymous callers cannot send to All', true, null);
  when others then
    insert into res(step, ok, info) values ('5 anonymous callers cannot send to All', false, sqlerrm);
  end;
  begin
    perform public.lucky_box_pull_back(gen_random_uuid());
    insert into res(step, ok, info) values ('5 anonymous callers cannot pull back', false, 'it ran');
  exception when insufficient_privilege then
    insert into res(step, ok, info) values ('5 anonymous callers cannot pull back', true, null);
  when others then
    insert into res(step, ok, info) values ('5 anonymous callers cannot pull back', false, sqlerrm);
  end;
end
$$;
reset role;

-- 6. Realtime announces app_config; the sweep runs every 15 s
insert into res(step, ok, info)
  select '6 app_config is in the Realtime publication', count(*) = 1, null
    from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_config';
insert into res(step, ok, info)
  select '6 the stale-presence sweep runs every 15 seconds', coalesce(bool_and(schedule = '15 seconds' and active), false), string_agg(schedule, ',')
    from cron.job where jobname = 'finalize-stale-presence';

select n, step, ok, info from res order by n;

rollback;
