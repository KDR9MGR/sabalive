-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/tulasi_game_monitoring_test.sql
-- Proves (20261013120000): a player who won in games and gifted the same day shows up, a host's inflow splits out the part
-- that came from game winners, and a player who lost does not show up.
insert into auth.users (id, email) values
  ('a9200000-0000-0000-0000-000000000001', 'winner@x'), ('b9200000-0000-0000-0000-000000000002', 'loser@x'), ('c9200000-0000-0000-0000-000000000003', 'host@x');
insert into public.gifts (id, name, emoji, price_coins) values ('99999999-9200-0000-0000-000000000001', 'Rose', 'R', 100);
insert into public.game_players (profile_id) values ('a9200000-0000-0000-0000-000000000001'), ('b9200000-0000-0000-0000-000000000002');
insert into public.game_transactions (transaction_id, profile_id, game_uid, type, coin, status) values
  ('m1', 'a9200000-0000-0000-0000-000000000001', 10001, 0, 100, 'ok'), ('m2', 'a9200000-0000-0000-0000-000000000001', 10001, 1, 5000, 'ok'),
  ('m3', 'b9200000-0000-0000-0000-000000000002', 10002, 0, 700, 'ok'), ('m4', 'b9200000-0000-0000-0000-000000000002', 10002, 1, 100, 'ok');
insert into public.gift_transactions (sender_id, receiver_id, gift_id, coins) values
  ('a9200000-0000-0000-0000-000000000001', 'c9200000-0000-0000-0000-000000000003', '99999999-9200-0000-0000-000000000001', 3000),
  ('b9200000-0000-0000-0000-000000000002', 'c9200000-0000-0000-0000-000000000003', '99999999-9200-0000-0000-000000000001', 200);
select '1 the winner who gifted shows up (expect 1 row, net 4900, gifted 3000)' as check, count(*) as n, max(game_net) as net, max(gifted) as gifted
  from public.game_winner_gifting where profile_id = 'a9200000-0000-0000-0000-000000000001';
select '1b the loser does not (expect 0)' as check, count(*) as n from public.game_winner_gifting where profile_id = 'b9200000-0000-0000-0000-000000000002';
select '2 the host received 3200, 3000 of it from a game winner (expect 3200, 3000, 1)' as check, received, from_game_winners, winner_senders
  from public.game_host_inflow where host_id = 'c9200000-0000-0000-0000-000000000003';
