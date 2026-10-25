-- Exercises the gift quantity functions (20261025100000) on STAGING as real (fake) users with the real grants, then rolls back.
-- Run through scripts/staging/verify_gift_quantity.sh. Safe: one transaction that ends in ROLLBACK.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;

create temp table who as
select
  (select h.profile_id from public.host_profiles h
     join public.profiles p on p.id = h.profile_id
    where p.is_ghost = false and p.status = 'active'
      and exists (select 1 from public.host_grants g where g.profile_id = h.profile_id and g.status = 'active' and (g.expires_at is null or g.expires_at > now()))
      and not exists (select 1 from public.staff_roles s where s.user_id = h.profile_id)
    order by p.created_at desc limit 1) as host_id,
  (select p.id from public.profiles p
    where p.is_host = false and p.is_ghost = false and p.status = 'active' and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
    order by p.created_at desc limit 1) as viewer_id,
  (select p.id from public.profiles p
    where p.is_host = false and p.is_ghost = false and p.status = 'active' and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
    order by p.created_at asc limit 1) as guest_id;
grant select on who to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

do $$
declare
  sid uuid;
  gid uuid;
begin
  if (select host_id from who) is null or (select viewer_id from who) is null or (select guest_id from who) is null or (select viewer_id from who) = (select guest_id from who) then
    insert into res(step, ok, info) values ('setup: a host and two different ordinary users exist on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  insert into public.live_streams (host_id, title, status, mode, last_heartbeat_at)
    values ((select host_id from who), 'zz-smoke-test gift quantity', 'live', 'audio', now()) returning id into sid;
  insert into ids values ('stream', sid::text);
  select id into gid from public.gifts where status = 'active' order by price_coins limit 1;
  insert into ids values ('gift', gid::text);
  insert into ids values ('price', (select price_coins::text from public.gifts where id = gid));
  insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at) values (sid, 2, (select guest_id from who), now());
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values ((select viewer_id from who), 'purchase', 'coins', 100000, 'coin_purchases', 'zz-smoke-test funds');
  insert into ids values ('coins_before', (select coins::text from public.wallets where profile_id = (select viewer_id from who)));
end
$$;

set local role authenticated;

do $$
declare
  v uuid := (select viewer_id from who);
  h uuid := (select host_id from who);
  g uuid := (select guest_id from who);
  sid uuid := (select val::uuid from ids where k = 'stream');
  gid uuid := (select val::uuid from ids where k = 'gift');
  price int := (select val::int from ids where k = 'price');
  r record;
  n int;
begin
  if sid is null then return; end if;
  perform set_config('request.jwt.claim.sub', v::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);

  begin
    n := public.send_gift_v2(gid, h, sid, 10);
    select body, gift_count, gift_receiver_ids into r from public.live_chat_messages where live_stream_id = sid and kind = 'gift' order by id desc limit 1;
    insert into res(step, ok, info) values ('1 a x10 gift is ONE call and ONE line that says 10x', n = 10 and r.gift_count = 10 and r.body like '% 10x %' and r.gift_receiver_ids = array[h], r.body);
  exception when others then
    insert into res(step, ok, info) values ('1 a x10 gift', false, sqlerrm);
  end;

  begin
    n := public.send_gift_to_all_v2(gid, sid, 3);
    select body, to_all, gift_count, gift_receiver_ids into r from public.live_chat_messages where live_stream_id = sid and kind = 'gift' order by id desc limit 1;
    insert into res(step, ok, info) values ('2 Send to All x3 reaches the host and the guest, never me, in ONE line',
      n = 2 and r.to_all and r.gift_count = 3 and r.body = 'sent 3x ' || (select name from public.gifts where id = gid) || ' ' || (select emoji from public.gifts where id = gid) || ' to 2 people'
      and r.gift_receiver_ids @> array[h, g] and not (v = any (r.gift_receiver_ids)), r.body);
  exception when others then
    insert into res(step, ok, info) values ('2 Send to All x3', false, sqlerrm);
  end;

  begin
    perform public.send_gift_v2(gid, h, sid, 100);
    insert into res(step, ok, info) values ('3 a quantity of 100 is refused', false, 'it was allowed');
  exception when others then
    insert into res(step, ok, info) values ('3 a quantity of 100 is refused', sqlerrm like 'Pick a quantity%', sqlerrm);
  end;

  select count(*) into n from public.live_chat_messages where live_stream_id = sid and kind = 'gift';
  insert into res(step, ok, info) values ('4 two chat lines in all for 10 + 6 gift units (not 16)', n = 2, 'lines: ' || n);

  insert into res(step, ok, info)
    select '5 the sender paid exactly price x (10 + 2 people x 3)', (select val::bigint from ids where k = 'coins_before') - w.coins = price::bigint * 16, 'paid ' || ((select val::bigint from ids where k = 'coins_before') - w.coins) || ' for price ' || price
      from public.wallets w where w.profile_id = v;
end
$$;
reset role;

insert into res(step, ok, info)
  select '6 anonymous callers cannot send gifts', not has_function_privilege('anon', 'public.send_gift_v2(uuid,uuid,uuid,integer)', 'execute')
         and not has_function_privilege('anon', 'public.send_gift_to_all_v2(uuid,uuid,integer)', 'execute'), null;

select n, step, ok, info from res order by n;

rollback;
