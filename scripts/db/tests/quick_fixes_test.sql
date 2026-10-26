-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/quick_fixes_test.sql
-- Proves (20261026140000): send_gift_to_all_v3 includes the sender when they are the host or sit on a seat (price x people x quantity, the sender is paid their own share in
-- diamonds, ONE chat line, the sender is in the recipient list), a sender who is only a viewer is not among the people, v2 still leaves the sender out; the diamond reset is the
-- reset_diamonds permission (on for a Master by default, an explicit false blocks it, a Super Admin always has it, a lower role never does even if the key is saved);
-- set_staff_permissions knows the key; nobody can call the new function without signing in.
insert into auth.users (id, email) values
  ('a7000000-0000-0000-0000-000000000001', 'host7@x'),
  ('b7000000-0000-0000-0000-000000000002', 'guest7@x'),
  ('d7000000-0000-0000-0000-000000000004', 'sender7@x'),
  ('f7000000-0000-0000-0000-000000000006', 'viewer7@x'),
  ('a1000000-0000-0000-0000-0000000000a1', 'master@x'),
  ('e1000000-0000-0000-0000-0000000000e6', 'super@x'),
  ('f1000000-0000-0000-0000-0000000000f7', 'global@x');
insert into public.staff_roles (user_id, role) values
  ('a1000000-0000-0000-0000-0000000000a1', 'admin'),
  ('e1000000-0000-0000-0000-0000000000e6', 'super_admin'),
  ('f1000000-0000-0000-0000-0000000000f7', 'global_admin');
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at)
values ('77777777-7777-7777-7777-777777777777', 'a7000000-0000-0000-0000-000000000001', 'v3 test', 'live', 'audio', now());
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at) values
  ('77777777-7777-7777-7777-777777777777', 1, 'a7000000-0000-0000-0000-000000000001', now()),
  ('77777777-7777-7777-7777-777777777777', 2, 'b7000000-0000-0000-0000-000000000002', now()),
  ('77777777-7777-7777-7777-777777777777', 3, 'd7000000-0000-0000-0000-000000000004', now());   -- the sender sits
insert into public.gifts (id, name, emoji, price_coins) values ('98989898-9898-9898-9898-989898989898', 'Rose7', 'R', 10);
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values
  ('d7000000-0000-0000-0000-000000000004', 'purchase', 'coins', 1000, 'coin_purchases', 'funds'),
  ('f7000000-0000-0000-0000-000000000006', 'purchase', 'coins', 1000, 'coin_purchases', 'funds');

create or replace function pg_temp.as_user(p_id text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_id, false); $$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

-- 1. a seated sender: Send to All reaches host + guest + THEMSELVES = 3 people
select pg_temp.as_user('d7000000-0000-0000-0000-000000000004');
create temp table r1 as select public.send_gift_to_all_v3('98989898-9898-9898-9898-989898989898', '77777777-7777-7777-7777-777777777777', 2) as n;
select '1 three people, the sender among them (expect 3)' as check, n from r1;
select '1b charged 3 people x 2 x 10 = 60 (expect 940)' as check, coins as coins from public.wallets where profile_id = 'd7000000-0000-0000-0000-000000000004';
select '1c the sender got their own share back as diamonds: 2 x 10 (expect 20); host and guest the same (expect 20, 20)' as check,
  (select diamonds from public.wallets where profile_id = 'd7000000-0000-0000-0000-000000000004') as sender,
  (select diamonds from public.wallets where profile_id = 'a7000000-0000-0000-0000-000000000001') as host,
  (select diamonds from public.wallets where profile_id = 'b7000000-0000-0000-0000-000000000002') as guest;
select '1d six gift rows (3 people x 2) (expect 6), the stream total 60 (expect 60)' as check,
  (select count(*) from public.gift_transactions where sender_id = 'd7000000-0000-0000-0000-000000000004') as rows,
  (select gift_coin_total from public.live_streams where id = '77777777-7777-7777-7777-777777777777') as total;
select '1e ONE chat line, to all, count 2, three receivers including the sender (expect 1, t, 2, 3, t)' as check,
  count(*) as lines, bool_and(to_all) as to_all, min(gift_count) as qty, min(cardinality(gift_receiver_ids)) as receivers,
  bool_and('d7000000-0000-0000-0000-000000000004'::uuid = any(gift_receiver_ids)) as sender_in
  from public.live_chat_messages where live_stream_id = '77777777-7777-7777-7777-777777777777' and kind = 'gift';
select '1f the line says how many people (expect sent 2x Rose7 R to 3 people)' as check, body from public.live_chat_messages where kind = 'gift' and live_stream_id = '77777777-7777-7777-7777-777777777777';

-- 2. a viewer who is not on a seat is not among the people: host + two seated = 3 (they pay for 3, nothing comes back to them)
select pg_temp.as_user('f7000000-0000-0000-0000-000000000006');
create temp table r2 as select public.send_gift_to_all_v3('98989898-9898-9898-9898-989898989898', '77777777-7777-7777-7777-777777777777', 1) as n;
select '2 a viewer reaches 3 people, charged 30, gets nothing (expect 3, 970, 0)' as check, (select n from r2) as n,
  (select coins from public.wallets where profile_id = 'f7000000-0000-0000-0000-000000000006') as coins,
  (select diamonds from public.wallets where profile_id = 'f7000000-0000-0000-0000-000000000006') as diamonds;

-- 3. v2 is untouched: it still leaves the seated sender out (2 people)
select pg_temp.as_user('d7000000-0000-0000-0000-000000000004');
select '3 v2 still skips the sender (expect 2)' as check, public.send_gift_to_all_v2('98989898-9898-9898-9898-989898989898', '77777777-7777-7777-7777-777777777777', 1) as n;

-- 4. a host alone in the room can send to All (only themselves)
update public.live_stream_seats set occupant_id = null where false;
delete from public.live_stream_seats where live_stream_id = '77777777-7777-7777-7777-777777777777' and occupant_id <> 'a7000000-0000-0000-0000-000000000001';
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values ('a7000000-0000-0000-0000-000000000001', 'purchase', 'coins', 100, 'coin_purchases', 'funds');
select pg_temp.as_user('a7000000-0000-0000-0000-000000000001');
create temp table r4 as select public.send_gift_to_all_v3('98989898-9898-9898-9898-989898989898', '77777777-7777-7777-7777-777777777777', 1) as n;
select '4 a host alone reaches 1 person: themselves (expect 1)' as check, n from r4;

-- 5. checks
select pg_temp.as_user('');
select '5 signed out is refused (expect t)' as check, pg_temp.refused('select public.send_gift_to_all_v3(''98989898-9898-9898-9898-989898989898'', ''77777777-7777-7777-7777-777777777777'', 1)', 'Must be signed in%') as ok;
select pg_temp.as_user('d7000000-0000-0000-0000-000000000004');
select '5b a quantity of 100 is refused (expect t)' as check, pg_temp.refused('select public.send_gift_to_all_v3(''98989898-9898-9898-9898-989898989898'', ''77777777-7777-7777-7777-777777777777'', 100)', 'Pick a quantity%') as ok;
select '5c anon cannot call it (expect f)' as check, has_function_privilege('anon', 'public.send_gift_to_all_v3(uuid,uuid,integer)', 'execute') as anon;

-- 6. the diamond reset is a permission
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select '6 a Master has it by default (expect t)' as check, (public.admin_diamond_reset_preview('2026-01') is not null) as ok;
select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e6');
select '6b the Super Admin switches it OFF for the Master: the key is accepted (expect {"reset_diamonds": false})' as check,
  public.set_staff_permissions('a1000000-0000-0000-0000-0000000000a1', '{"reset_diamonds": false}'::jsonb) as saved;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select '6c ... and the Master is refused at once, preview and reset (expect t, t)' as check,
  pg_temp.refused('select public.admin_diamond_reset_preview(''2026-01'')', '%Only a Master or Super Admin%') as preview,
  pg_temp.refused('select public.admin_reset_diamonds(''2026-01'', ''gift'', ''2026-01'')', '%Only a Master or Super Admin%') as reset;
select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e6');
select '6d the Super Admin always has it (expect t)' as check, (public.admin_diamond_reset_preview('2026-01') is not null) as ok;
select public.set_staff_permissions('a1000000-0000-0000-0000-0000000000a1', '{"reset_diamonds": true}'::jsonb);
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select '6e switched back ON: the Master is allowed again (expect t)' as check, (public.admin_diamond_reset_preview('2026-01') is not null) as ok;
select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e6');
select '6f the key can be saved on a Global Admin, but it never opens the reset (expect t)' as check,
  (public.set_staff_permissions('f1000000-0000-0000-0000-0000000000f7', '{"reset_diamonds": true}'::jsonb) ->> 'reset_diamonds')::boolean as saved;
select pg_temp.as_user('f1000000-0000-0000-0000-0000000000f7');
select '6g ... a Global Admin with the key is still refused (expect t)' as check,
  pg_temp.refused('select public.admin_diamond_reset_preview(''2026-01'')', '%Only a Master or Super Admin%') as ok;
select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e6');
select '6h an unknown key is still refused (expect t)' as check,
  pg_temp.refused('select public.set_staff_permissions(''a1000000-0000-0000-0000-0000000000a1'', ''{"nonsense": true}''::jsonb)', 'Unknown permission%') as ok;
