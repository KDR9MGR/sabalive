-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/send_gift_to_all_test.sql
-- Proves: one call gifts the host and every seated guest (never the sender), charges price x people, writes the same
-- ledger/gift rows as send_gift, posts ONE "to All" line, and refuses (without charging) when the balance is short.
insert into auth.users (id, email) values
  ('a6000000-0000-0000-0000-000000000001', 'host6@x'),
  ('b6000000-0000-0000-0000-000000000002', 'guest6a@x'),
  ('c6000000-0000-0000-0000-000000000003', 'guest6b@x'),
  ('d6000000-0000-0000-0000-000000000004', 'sender6@x'),
  ('e6000000-0000-0000-0000-000000000005', 'poor6@x');
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at)
values ('66666666-6666-6666-6666-666666666666', 'a6000000-0000-0000-0000-000000000001', 'all test', 'live', 'audio', now());
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at) values
  ('66666666-6666-6666-6666-666666666666', 1, 'a6000000-0000-0000-0000-000000000001', now()),   -- the host (also the host id)
  ('66666666-6666-6666-6666-666666666666', 2, 'b6000000-0000-0000-0000-000000000002', now()),
  ('66666666-6666-6666-6666-666666666666', 3, 'c6000000-0000-0000-0000-000000000003', now()),
  ('66666666-6666-6666-6666-666666666666', 4, 'd6000000-0000-0000-0000-000000000004', now());   -- the sender sits too
insert into public.gifts (id, name, emoji, price_coins) values ('99999999-9999-9999-9999-999999999999', 'Rose', 'R', 10);
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values
  ('d6000000-0000-0000-0000-000000000004', 'purchase', 'coins', 100, 'coin_purchases', 'test funds'),
  ('e6000000-0000-0000-0000-000000000005', 'purchase', 'coins', 20, 'coin_purchases', 'test funds');

-- 1. the sender sends Rose (10 coins) to All: host + 2 guests = 3 people, the sender's own seat is skipped
select set_config('request.jwt.claim.sub', 'd6000000-0000-0000-0000-000000000004', false);
select '1 returns the number of people (expect 3)' as check, public.send_gift_to_all('99999999-9999-9999-9999-999999999999', '66666666-6666-6666-6666-666666666666') as n;
select '1 sender paid 3 x 10 (expect 70 left)' as check, coins as n from public.wallets where profile_id = 'd6000000-0000-0000-0000-000000000004';
select '1 each of the 3 got 10 diamonds (expect 3)' as check, count(*) as n from public.wallets where diamonds = 10
  and profile_id in ('a6000000-0000-0000-0000-000000000001', 'b6000000-0000-0000-0000-000000000002', 'c6000000-0000-0000-0000-000000000003');
select '1 sender got nothing (expect 0)' as check, diamonds as n from public.wallets where profile_id = 'd6000000-0000-0000-0000-000000000004';
select '1 three gift rows (expect 3)' as check, count(*) as n from public.gift_transactions where sender_id = 'd6000000-0000-0000-0000-000000000004';
select '1 stream total (expect 30)' as check, gift_coin_total as n from public.live_streams where id = '66666666-6666-6666-6666-666666666666';
select '1 ONE chat line, to_all, carries the gift (expect 1, t, "sent Rose R to All")' as check,
       count(*) as n, bool_and(to_all) as flag, min(body) as body, bool_and(gift_id is not null) as has_gift
  from public.live_chat_messages where live_stream_id = '66666666-6666-6666-6666-666666666666' and kind = 'gift';

-- 2. a short balance is refused and charges nothing
select set_config('request.jwt.claim.sub', 'e6000000-0000-0000-0000-000000000005', false);
do $$ begin
  perform public.send_gift_to_all('99999999-9999-9999-9999-999999999999', '66666666-6666-6666-6666-666666666666');
  raise exception 'expected Insufficient coins';
exception when others then
  if sqlerrm <> 'Insufficient coins' then raise; end if;
end $$;
select '2 poor user still has 20 (expect 20)' as check, coins as n from public.wallets where profile_id = 'e6000000-0000-0000-0000-000000000005';

-- 3. an ended live is refused
select set_config('request.jwt.claim.sub', 'd6000000-0000-0000-0000-000000000004', false);
update public.live_streams set status = 'ended', ended_at = now() where id = '66666666-6666-6666-6666-666666666666';
do $$ begin
  perform public.send_gift_to_all('99999999-9999-9999-9999-999999999999', '66666666-6666-6666-6666-666666666666');
  raise exception 'expected live ended';
exception when others then
  if sqlerrm <> 'This live has ended' then raise; end if;
end $$;
select '3 ended live refused, nothing charged (expect 70)' as check, coins as n from public.wallets where profile_id = 'd6000000-0000-0000-0000-000000000004';

-- 4. nobody signed in is refused
select set_config('request.jwt.claim.sub', '', false);
do $$ begin
  perform public.send_gift_to_all('99999999-9999-9999-9999-999999999999', '66666666-6666-6666-6666-666666666666');
  raise exception 'expected sign-in error';
exception when others then
  if sqlerrm <> 'Must be signed in to send a gift' then raise; end if;
end $$;
select '4 signed-out call refused (expect t)' as check, true as ok;
