-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/gift_notices_test.sql
-- Proves (20261107110000_gift_notices): a gift send that costs at least 5,000 coins (price x quantity x people, written as ONE gift chat row by every version of the send functions)
-- leaves one notice with the sender, the receiver, the gift and the cost; a cheaper send, a plain chat line and a ghost sender do not; a gift to everyone names no
-- receiver; an older send (no receiver list) is a gift to the room's host; old notices are cleared; a notice problem never blocks the chat row; signed-in users can read the notices and
-- nobody can write them. Every line ends in ok = t; the last line says ALL PASSED or how many failed.
set time zone 'UTC';
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'sender@x'), ('a2000000-0000-0000-0000-000000000002', 'host@x'),
  ('a3000000-0000-0000-0000-000000000003', 'guest@x'), ('a4000000-0000-0000-0000-000000000004', 'ghost@x');
set session_replication_role = replica;
update public.profiles set is_ghost = true where id = 'a4000000-0000-0000-0000-000000000004';
set session_replication_role = origin;
update public.profiles set name = 'Sender One', avatar_url = 'https://x/s.png' where id = 'a1000000-0000-0000-0000-000000000001';
update public.profiles set name = 'Host Two', avatar_url = 'https://x/h.png' where id = 'a2000000-0000-0000-0000-000000000002';
update public.profiles set name = 'Guest Three', avatar_url = 'https://x/g.png' where id = 'a3000000-0000-0000-0000-000000000003';
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at) values
  ('f1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 'room', 'live', 'audio', now(), now());
insert into public.gifts (id, name, emoji, price_coins, icon_url) values
  ('91000000-0000-0000-0000-000000000001', 'Castle', '🏰', 5000, 'https://x/castle.png'),
  ('92000000-0000-0000-0000-000000000002', 'Rose', '🌹', 1000, null);

create temp table r (n serial, check_name text, ok boolean);
grant all on r to authenticated, anon;
grant usage, select on sequence r_n_seq to authenticated, anon;
create function pg_temp.refused(sql text) returns boolean language plpgsql as $$ begin execute sql; return false; exception when others then return true; end $$;

-- a gift chat row the way the send functions write it
create function pg_temp.gift_row(who uuid, gift uuid, qty int, receivers uuid[], all_ boolean default false, kind_ text default 'gift') returns void language plpgsql as $$
begin
  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, gift_id, to_all, gift_count, gift_receiver_ids)
  values ('f1000000-0000-0000-0000-000000000001', who, 'sent a gift', kind_, gift, all_, qty, receivers);
end $$;

insert into r(check_name, ok) select '1 the threshold lives in one function and is 5,000', public.gift_notice_min_coins() = 5000;

select pg_temp.gift_row('a1000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001', 1, array['a3000000-0000-0000-0000-000000000003'::uuid]);
insert into r(check_name, ok) select '2 one 5,000-coin gift to one person leaves one notice with the sender, the receiver, the gift and the cost',
  (select count(*) from public.gift_notices) = 1
  and (select (sender_name, sender_avatar_url, receiver_name, receiver_avatar_url, to_all, gift_name, gift_emoji, gift_icon_url, quantity, coins)::text from public.gift_notices)
      = '("Sender One",https://x/s.png,"Guest Three",https://x/g.png,f,Castle,🏰,https://x/castle.png,1,5000)';

select pg_temp.gift_row('a1000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000002', 4, array['a3000000-0000-0000-0000-000000000003'::uuid]);
insert into r(check_name, ok) select '3 4 x 1,000 = 4,000 leaves nothing', (select count(*) from public.gift_notices) = 1;

select pg_temp.gift_row('a1000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000002', 5, array['a3000000-0000-0000-0000-000000000003'::uuid]);
insert into r(check_name, ok) select '4 5 x 1,000 = 5,000 does (the quantity counts)', (select count(*) from public.gift_notices where gift_name = 'Rose' and quantity = 5 and coins = 5000) = 1;

select pg_temp.gift_row('a1000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000002', 1, array['a2000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000003'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, 'a4000000-0000-0000-0000-000000000004'::uuid, 'a2000000-0000-0000-0000-000000000002'::uuid], true);
insert into r(check_name, ok) select '5 a gift to everyone costs price x quantity x people, names no receiver and is marked to_all',
  (select count(*) from public.gift_notices where to_all and coins = 5000 and receiver_name is null and receiver_avatar_url is null) = 1;

select pg_temp.gift_row('a1000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001', null, null);
insert into r(check_name, ok) select '6 an older send (no quantity, no receiver list) counts as one gift to the room''s host',
  (select count(*) from public.gift_notices where receiver_name = 'Host Two' and quantity = 1 and coins = 5000 and not to_all) = 1;

insert into public.live_chat_messages (live_stream_id, sender_id, body, kind) values ('f1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'hello', 'text');
insert into r(check_name, ok) select '7 a plain chat line leaves nothing (and the trigger does not even run for it)', (select count(*) from public.gift_notices) = 4;

select pg_temp.gift_row('a4000000-0000-0000-0000-000000000004', '91000000-0000-0000-0000-000000000001', 1, array['a3000000-0000-0000-0000-000000000003'::uuid]);
insert into r(check_name, ok) select '8 a ghost sender never shows up', (select count(*) from public.gift_notices) = 4;

delete from public.gift_notices;
insert into r(check_name, ok) select '9 a chat row can only name a gift that exists (the foreign key), so the trigger never meets an unknown one',
  pg_temp.refused($q$insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, gift_id, gift_count) values ('f1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'sent', 'gift', '99999999-0000-0000-0000-000000000009', 1)$q$)
  and (select count(*) from public.gift_notices) = 0;

-- a gift with no icon, no emoji still gets a strip
update public.gifts set emoji = '', icon_url = '  ' where id = '92000000-0000-0000-0000-000000000002';
select pg_temp.gift_row('a1000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000002', 1, array['a3000000-0000-0000-0000-000000000003'::uuid]);
insert into r(check_name, ok) select '10 a gift with no picture and no emoji still gets one (the gift box emoji, no picture)',
  (select (gift_emoji, gift_icon_url)::text from public.gift_notices where gift_name = 'Rose') = '(🎁,)';

-- old notices go away with the next one
update public.gift_notices set created_at = now() - interval '3 days';
select pg_temp.gift_row('a1000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001', 1, array['a3000000-0000-0000-0000-000000000003'::uuid]);
insert into r(check_name, ok) select '11 notices older than 2 days are removed by the next one', (select count(*) from public.gift_notices) = 1;

-- a notice that cannot be written never blocks the chat row
alter table public.gift_notices add constraint zz_always_fails check (coins < 0) not valid;
select pg_temp.gift_row('a1000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001', 2, array['a3000000-0000-0000-0000-000000000003'::uuid]);
insert into r(check_name, ok) select '12 when the notice cannot be written the gift chat row is still saved',
  (select count(*) from public.live_chat_messages where gift_count = 2) = 1 and (select count(*) from public.gift_notices) = 1;
alter table public.gift_notices drop constraint zz_always_fails;

set role authenticated;
insert into r(check_name, ok) select '13 a signed-in user can read the notices', (select count(*) from public.gift_notices) >= 1;
insert into r(check_name, ok) select '14 nobody from the app can write, change or delete one',
  pg_temp.refused($q$insert into public.gift_notices (sender_id, sender_name, coins) values ('a1000000-0000-0000-0000-000000000001', 'x', 5000)$q$)
  and pg_temp.refused($q$update public.gift_notices set coins = 1$q$)
  and pg_temp.refused($q$delete from public.gift_notices$q$);
reset role;
set role anon;
insert into r(check_name, ok) select '15 a signed-out visitor cannot read them', pg_temp.refused($q$select * from public.gift_notices$q$);
reset role;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
