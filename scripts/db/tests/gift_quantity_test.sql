-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/gift_quantity_test.sql
-- Proves (20261025100000): a gift with a quantity is ONE call that charges price x quantity up front, writes the same ledger / gift rows once per unit and ONE chat line
-- ("sent <person> 10x Rose"); Send to All does the same for the host and every seated guest (never the sender) with ONE line ("sent 10x Rose to 3 people") and records
-- who the gift went to; short balances, bad quantities, ended lives and signed-out callers are refused without charging; the old functions still work.
insert into auth.users (id, email) values
  ('a7000000-0000-0000-0000-000000000001', 'host7@x'),
  ('b7000000-0000-0000-0000-000000000002', 'guest7a@x'),
  ('c7000000-0000-0000-0000-000000000003', 'guest7b@x'),
  ('d7000000-0000-0000-0000-000000000004', 'sender7@x'),
  ('e7000000-0000-0000-0000-000000000005', 'poor7@x');
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at)
values ('77777777-7777-7777-7777-777777777777', 'a7000000-0000-0000-0000-000000000001', 'gift quantity test', 'live', 'audio', now());
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at) values
  ('77777777-7777-7777-7777-777777777777', 1, 'a7000000-0000-0000-0000-000000000001', now()),   -- the host on a seat too
  ('77777777-7777-7777-7777-777777777777', 2, 'b7000000-0000-0000-0000-000000000002', now()),
  ('77777777-7777-7777-7777-777777777777', 3, 'c7000000-0000-0000-0000-000000000003', now()),
  ('77777777-7777-7777-7777-777777777777', 4, 'd7000000-0000-0000-0000-000000000004', now());   -- the sender sits too
insert into public.gifts (id, name, emoji, price_coins) values ('88888888-8888-8888-8888-888888888888', 'Rose', 'R', 10);
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values
  ('d7000000-0000-0000-0000-000000000004', 'purchase', 'coins', 1000, 'coin_purchases', 'test funds'),
  ('e7000000-0000-0000-0000-000000000005', 'purchase', 'coins', 50, 'coin_purchases', 'test funds');

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

select set_config('request.jwt.claim.sub', 'd7000000-0000-0000-0000-000000000004', false);

-- 1. one gift, quantity 1: the chat line is as before
select '1 returns the quantity (expect 1)' as check, public.send_gift_v2('88888888-8888-8888-8888-888888888888', 'b7000000-0000-0000-0000-000000000002', '77777777-7777-7777-7777-777777777777', 1) as n;
select '1b the chat line has no multiplier, records the count and the receiver (expect "sent guest7a... Rose R", 1, t)' as check,
       body, gift_count, gift_receiver_ids = array['b7000000-0000-0000-0000-000000000002'::uuid] as receiver_ok
  from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift' order by id desc limit 1;

-- 2. one gift, quantity 10: ONE call, ONE line
select '2 returns 10' as check, public.send_gift_v2('88888888-8888-8888-8888-888888888888', 'b7000000-0000-0000-0000-000000000002', '77777777-7777-7777-7777-777777777777', 10) as n;
select '2b the sender paid 10 x 10 more (expect 1000 - 10 - 100 = 890)' as check, coins as n from public.wallets where profile_id = 'd7000000-0000-0000-0000-000000000004';
select '2c the receiver got 11 x 10 diamonds (expect 110)' as check, diamonds as n from public.wallets where profile_id = 'b7000000-0000-0000-0000-000000000002';
select '2d ten gift rows for the x10 (expect 11 in all)' as check, count(*) as n from public.gift_transactions where sender_id = 'd7000000-0000-0000-0000-000000000004' and receiver_id = 'b7000000-0000-0000-0000-000000000002';
select '2e the stream total moved by 100 + 10 (expect 110)' as check, gift_coin_total as n from public.live_streams where id = '77777777-7777-7777-7777-777777777777';
select '2f ONE line for the x10 carrying "10x" and gift_count 10 (expect 2 lines in all, "10x Rose", 10)' as check,
       (select count(*) from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift') as lines,
       (select body from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift' order by id desc limit 1) as body,
       (select gift_count from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift' order by id desc limit 1) as gift_count;

-- 3. send to all, quantity 1 and 10: host + 2 guests = 3 people (the sender's own seat is skipped)
select '3 to all x1 returns 3 people' as check, public.send_gift_to_all_v2('88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777', 1) as n;
select '3b the line says how many people and 1x (expect "sent 1x Rose R to 3 people", t, 1, 3 receivers)' as check,
       body, to_all, gift_count, cardinality(gift_receiver_ids) as receivers,
       not ('d7000000-0000-0000-0000-000000000004'::uuid = any (gift_receiver_ids)) as sender_not_a_receiver
  from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift' order by id desc limit 1;
select '3c to all x10 returns 3' as check, public.send_gift_to_all_v2('88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777', 10) as n;
select '3d the x10 line (expect "sent 10x Rose R to 3 people", 10)' as check, body, gift_count
  from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift' order by id desc limit 1;
select '3e the sender paid 3 x 10 then 3 x 100 more (expect 890 - 30 - 300 = 560)' as check, coins as n from public.wallets where profile_id = 'd7000000-0000-0000-0000-000000000004';
select '3f the host got 10 + 100 diamonds (expect 110)' as check, diamonds as n from public.wallets where profile_id = 'a7000000-0000-0000-0000-000000000001';

-- 4. refusals charge nothing
select set_config('request.jwt.claim.sub', 'e7000000-0000-0000-0000-000000000005', false);
select '4 a short balance for x10 to all is refused (expect t)' as check,
       pg_temp.refused('select public.send_gift_to_all_v2(''88888888-8888-8888-8888-888888888888'', ''77777777-7777-7777-7777-777777777777'', 10)', 'Insufficient coins') as ok;
select '4b ...and a short balance for a single x10 (expect t)' as check,
       pg_temp.refused('select public.send_gift_v2(''88888888-8888-8888-8888-888888888888'', ''a7000000-0000-0000-0000-000000000001'', ''77777777-7777-7777-7777-777777777777'', 10)', 'Insufficient coins') as ok;
select '4c the poor user still has 50 (expect 50)' as check, coins as n from public.wallets where profile_id = 'e7000000-0000-0000-0000-000000000005';
select '4d quantity 0 and 100 are refused (expect t, t)' as check,
       pg_temp.refused('select public.send_gift_v2(''88888888-8888-8888-8888-888888888888'', ''a7000000-0000-0000-0000-000000000001'', ''77777777-7777-7777-7777-777777777777'', 0)', 'Pick a quantity%') as zero,
       pg_temp.refused('select public.send_gift_to_all_v2(''88888888-8888-8888-8888-888888888888'', ''77777777-7777-7777-7777-777777777777'', 100)', 'Pick a quantity%') as hundred;
select '4e an unknown gift is refused (expect t)' as check,
       pg_temp.refused('select public.send_gift_v2(gen_random_uuid(), ''a7000000-0000-0000-0000-000000000001'', null, 1)', 'Unknown or inactive gift') as ok;
select set_config('request.jwt.claim.sub', '', false);
select '4f signed out is refused (expect t, t)' as check,
       pg_temp.refused('select public.send_gift_v2(''88888888-8888-8888-8888-888888888888'', ''a7000000-0000-0000-0000-000000000001'', null, 1)', 'Must be signed in%') as single,
       pg_temp.refused('select public.send_gift_to_all_v2(''88888888-8888-8888-8888-888888888888'', ''77777777-7777-7777-7777-777777777777'', 1)', 'Must be signed in%') as to_all;

-- 5. a gift without a live writes no chat line; a gift to myself has no name in the line
select set_config('request.jwt.claim.sub', 'd7000000-0000-0000-0000-000000000004', false);
select '5 outside a live the gift goes through' as check, public.send_gift_v2('88888888-8888-8888-8888-888888888888', 'a7000000-0000-0000-0000-000000000001', null, 2) as n;
select '5a ...with no chat line (expect still 4 lines)' as check, count(*) as lines from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift';
select '5b a gift to myself x3 returns 3' as check, public.send_gift_v2('88888888-8888-8888-8888-888888888888', 'd7000000-0000-0000-0000-000000000004', '77777777-7777-7777-7777-777777777777', 3) as n;
select '5c ...and reads "sent 3x Rose R", with no name (expect "sent 3x Rose R")' as check, body, gift_receiver_ids = array['d7000000-0000-0000-0000-000000000004'::uuid] as receiver_is_me
  from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift' order by id desc limit 1;

-- 6. the OLD functions still work exactly as before (old apps)
select '6 the old send_gift works' as check, (public.send_gift('88888888-8888-8888-8888-888888888888', 'b7000000-0000-0000-0000-000000000002', '77777777-7777-7777-7777-777777777777')).id is not null as ok;
select '6b ...and its line has no count and no receivers (expect null, null)' as check, gift_count, gift_receiver_ids
  from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift' order by id desc limit 1;
select '6c the old send_gift_to_all works' as check, public.send_gift_to_all('88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777') as n;
select '6d ...and still says "to All" (expect "sent Rose R to All", null)' as check, body, gift_count
  from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift' order by id desc limit 1;

-- 7. an ended live is refused by Send to All
update public.live_streams set status = 'ended', ended_at = now() where id = '77777777-7777-7777-7777-777777777777';
select '7 an ended live is refused (expect t)' as check,
       pg_temp.refused('select public.send_gift_to_all_v2(''88888888-8888-8888-8888-888888888888'', ''77777777-7777-7777-7777-777777777777'', 1)', 'This live has ended') as ok;

-- 8. permissions
select '8 signed-in users may call both, anon may not (expect t, t, f, f)' as check,
       has_function_privilege('authenticated', 'public.send_gift_v2(uuid,uuid,uuid,integer)', 'execute') as single_authed,
       has_function_privilege('authenticated', 'public.send_gift_to_all_v2(uuid,uuid,integer)', 'execute') as all_authed,
       has_function_privilege('anon', 'public.send_gift_v2(uuid,uuid,uuid,integer)', 'execute') as single_anon,
       has_function_privilege('anon', 'public.send_gift_to_all_v2(uuid,uuid,integer)', 'execute') as all_anon;
