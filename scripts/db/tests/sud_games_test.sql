-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/sud_games_test.sql
-- Proves (20261026110000): the SUD switches default OFF and need the master games switch; the panel list is Admin-only and validated; a signed-in person sees
-- only enabled, un-hidden SUD games; sud_launch_check refuses ghosts / paused / hidden / off games and, for a coin game, a missing coin switch, a missing or
-- too-young date of birth; the room id is cleaned; sud_user_info answers; sud_apply_score moves coins exactly once per order with the Tulasi limits (a bet needs
-- the coins and obeys max_bet and the daily limits, a win needs a bet and obeys the payout multiple, a repeat is code 9001, a paused game still pays a win), keeps
-- refusals for a human, writes the ledger kinds; the event log is capped; nothing is callable by anon.
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-0000000000a1', 'admin@x'),
  ('b1000000-0000-0000-0000-0000000000b2', 'p1@x'),
  ('b2000000-0000-0000-0000-0000000000b3', 'p2@x'),
  ('c1000000-0000-0000-0000-0000000000c4', 'young@x'),
  ('d1000000-0000-0000-0000-0000000000d5', 'ghost@x'),
  ('e1000000-0000-0000-0000-0000000000e6', 'super@x');
insert into public.staff_roles (user_id, role) values ('a1000000-0000-0000-0000-0000000000a1', 'admin'), ('e1000000-0000-0000-0000-0000000000e6', 'super_admin');
set session_replication_role = replica;
update public.profiles set is_ghost = true where id = 'd1000000-0000-0000-0000-0000000000d5';
set session_replication_role = origin;
update public.profiles set date_of_birth = '1990-01-01', name = 'Asha Rao', gender = 'female' where id = 'b1000000-0000-0000-0000-0000000000b2';
update public.profiles set date_of_birth = '1991-02-02', name = 'Bilal', gender = 'other' where id = 'b2000000-0000-0000-0000-0000000000b3';
update public.profiles set date_of_birth = (current_date - interval '15 years')::date where id = 'c1000000-0000-0000-0000-0000000000c4';
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values
  ('b1000000-0000-0000-0000-0000000000b2', 'purchase', 'coins', 100000, 'coin_purchases', 'funds'),
  ('b2000000-0000-0000-0000-0000000000b3', 'purchase', 'coins', 500, 'coin_purchases', 'funds');

create or replace function pg_temp.as_user(p_id text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_id, false); $$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
-- the release switches can only be changed by the Super Admin: do it as them, then go back to whoever was acting
create or replace function pg_temp.set_flags(p_json text) returns void language plpgsql as $$
declare v_prev text := current_setting('request.jwt.claim.sub', true);
begin
  perform set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e6', false);
  update public.app_config set feature_flags = coalesce(feature_flags, '{}'::jsonb) || p_json::jsonb where id;
  perform set_config('request.jwt.claim.sub', coalesce(v_prev, ''), false);
end $$;
create or replace function pg_temp.coins(p_id text) returns bigint language sql as $$ select coins from public.wallets where profile_id = p_id::uuid; $$;

-- 1. the switches default off
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');
select '1 the switches are off by default (expect f, f)' as check, public._sud_enabled() as sud, public._sud_coins_enabled() as coins;
select pg_temp.set_flags('{"sud_games_enabled": true}');
select '1b SUD alone is not enough without the master games switch (expect f)' as check, public._sud_enabled() as sud;
select pg_temp.set_flags('{"games_enabled": true}');
select '1c both on (expect t, and coin games still f)' as check, public._sud_enabled() as sud, public._sud_coins_enabled() as coins;

-- 2. the panel list
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');
select '2 an ordinary user cannot save (expect t)' as check, pg_temp.refused('select public.admin_save_sud_game(''1468180338417074177'', ''Ludo'')', 'Not allowed') as ok;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
create temp table ids as
  select (select public.admin_save_sud_game('1468180338417074177', '  Ludo  ', 1.0, false, 'https://img.example.com/ludo.png', 'Classic Ludo', 1, 10)) as ludo,
         (select public.admin_save_sud_game('1557194487352053761', 'TeenPatti', 1.0, true, null, null, 1, 20)) as teen;
select '2b saved, trimmed, ids start at 1,000,000 (expect Ludo, t)' as check, name, id >= 1000000 as big_id from public.sud_games where provider_game_id = '1468180338417074177';
select public.admin_save_sud_game('1468180338417074177', 'Ludo Plus', 1.0, false, null, null, 1, 10);
select '2c saving the same game id again updates it, no duplicate (expect 2, Ludo Plus)' as check,
       (select count(*) from public.sud_games) as n,
       (select name from public.sud_games where provider_game_id = '1468180338417074177') as name;
select public.admin_save_sud_game('1468180338417074177', 'Ludo', 1.0, false, 'https://img.example.com/ludo.png', 'Classic Ludo', 1, 10);
select '2d bad input is refused (expect t, t, t, t, t)' as check,
  pg_temp.refused('select public.admin_save_sud_game(''abc'', ''X'')', '%digits only%') as bad_id,
  pg_temp.refused('select public.admin_save_sud_game(''1234567'', '''')', '%name%') as bad_name,
  pg_temp.refused('select public.admin_save_sud_game(''1234567'', ''X'', 9)', '%between 0.25 and 4%') as bad_aspect,
  pg_temp.refused('select public.admin_save_sud_game(''1234567'', ''X'', 1, false, ''http://x'')', '%https%') as bad_image,
  pg_temp.refused('select public.admin_save_sud_game(''1234567'', ''X'', 1, false, null, null, 5)', '%Status%') as bad_status;

-- 3. what a player sees
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');
set role authenticated;
select '3 a signed-in person sees the 2 enabled games (expect 2)' as check, count(*) as n from public.sud_games;
reset role;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select public.admin_set_sud_games_hidden(array[(select teen from ids)], true);
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');
set role authenticated;
select '3b a hidden game disappears (expect 1)' as check, count(*) as n from public.sud_games;
reset role;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select public.admin_set_sud_games_hidden(array[(select teen from ids)], false);

-- 4. launching
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');
select '4 a party game launches; the room id is cleaned, the uid is the profile (expect t, Ludo, abc-123, 1468180338417074177)' as check,
       (r ->> 'ok')::boolean as ok, r ->> 'name' as name, r ->> 'room_id' as room, r ->> 'mg_id' as mg
  from (select public.sud_launch_check((select ludo from ids), 'abc 123!<>') as r) q;
select '4b no room given: a private table (expect solo-...)' as check, left(public.sud_launch_check((select ludo from ids)) ->> 'room_id', 5) as room;
select '4c the uid sent to SUD is the profile id (expect t)' as check, public.sud_launch_check((select ludo from ids)) ->> 'uid' = 'b1000000-0000-0000-0000-0000000000b2' as ok;
select '4d a coin game is closed while the coin switch is off (expect t)' as check, pg_temp.refused(format('select public.sud_launch_check(%s)', (select teen from ids)), '%not available%') as ok;
select pg_temp.set_flags('{"sud_coin_games_enabled": true}');
select '4e ... and opens when it is on (expect t)' as check, (public.sud_launch_check((select teen from ids)) ->> 'ok')::boolean as ok;
select pg_temp.as_user('c1000000-0000-0000-0000-0000000000c4');
select '4f a 15 year old may play a party game but not a coin game (expect t, t)' as check,
       (public.sud_launch_check((select ludo from ids)) ->> 'ok')::boolean as party,
       pg_temp.refused(format('select public.sud_launch_check(%s)', (select teen from ids)), '%aged 18 or over%') as coin_refused;
select pg_temp.as_user('d1000000-0000-0000-0000-0000000000d5');
select '4g a ghost account cannot play (expect t)' as check, pg_temp.refused(format('select public.sud_launch_check(%s)', (select ludo from ids)), '%cannot play games%') as ok;
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');
select '4h an unknown game (expect t)' as check, pg_temp.refused('select public.sud_launch_check(5)', '%not available%') as ok;
select pg_temp.set_flags('{"sud_games_enabled": false}');
select '4i the SUD switch off closes everything (expect t)' as check, pg_temp.refused(format('select public.sud_launch_check(%s)', (select ludo from ids)), '%not available right now%') as ok;
select pg_temp.set_flags('{"sud_games_enabled": true}');

-- 5. user info
select '5 name, avatar, gender (expect t, Asha Rao, female)' as check, (r ->> 'ok')::boolean as ok, r ->> 'nick_name' as name, r ->> 'gender' as gender
  from (select public.sud_user_info('b1000000-0000-0000-0000-0000000000b2') as r) q;
select '5b another gender becomes empty (expect empty)' as check, coalesce(nullif(public.sud_user_info('b2000000-0000-0000-0000-0000000000b3') ->> 'gender', ''), 'empty') as g;
select '5c unknown, ghost and non-uuid users are refused (expect f, f, f)' as check,
       (public.sud_user_info('99999999-9999-9999-9999-999999999999') ->> 'ok')::boolean as unknown,
       (public.sud_user_info('d1000000-0000-0000-0000-0000000000d5') ->> 'ok')::boolean as ghost,
       (public.sud_user_info('nope') ->> 'ok')::boolean as junk;

-- 6. coins. Limits for the test: max bet 1000, win limit none, payout multiple 5
update public.game_config set max_bet = 1000, daily_loss_limit = 0, daily_win_limit = 0, max_payout_multiple = 5 where id;
select '6 a bet takes the coins once (expect 0, 99900)' as check, (r ->> 'code')::int as code, (r ->> 'coin')::bigint as coin
  from (select public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-1', '1557194487352053761', 'round-1', 100, 1) as r) q;
select '6b the same order again is 9001 and charges nothing (expect 9001, 99900)' as check, (r ->> 'code')::int as code, pg_temp.coins('b1000000-0000-0000-0000-0000000000b2') as coin
  from (select public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-1', '1557194487352053761', 'round-1', 100, 1) as r) q;
select '6c someone else cannot reuse the order id (expect 1)' as check, (public.sud_apply_score('b2000000-0000-0000-0000-0000000000b3', 'ord-1', '1557194487352053761', 'round-1', 100, 1) ->> 'code')::int as code;
select '6d a win pays (expect 0, 100400)' as check, (r ->> 'code')::int as code, (r ->> 'coin')::bigint as coin
  from (select public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-2', '1557194487352053761', 'round-1', 500, 2) as r) q;
select '6e a win above 5 x what was bet is refused (bet 100, asks 600) (expect 1, win above the payout limit)' as check, (r ->> 'code')::int as code, r ->> 'msg' as msg
  from (select public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-3', '1557194487352053761', 'round-1', 600, 2) as r) q;
select '6f a win with no bet on that game is refused (expect win without a bet)' as check, r ->> 'msg' as msg
  from (select public.sud_apply_score('b2000000-0000-0000-0000-0000000000b3', 'ord-4', '1557194487352053761', 'round-9', 50, 2) as r) q;
select '6g a bet over max_bet is refused (expect 1, bet above the limit)' as check, (r ->> 'code')::int as code, r ->> 'msg' as msg
  from (select public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-5', '1557194487352053761', 'round-2', 1001, 1) as r) q;
select '6h a bet beyond the balance is 9000 (p2 has 500) (expect 9000)' as check, (public.sud_apply_score('b2000000-0000-0000-0000-0000000000b3', 'ord-6', '1557194487352053761', 'round-3', 600, 1) ->> 'code')::int as code;
select '6i a game that is not a coin game is refused (expect not a coin game)' as check, r ->> 'msg' as msg
  from (select public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-7', '1468180338417074177', 'round-4', 10, 1) as r) q;
select '6j wrong type, junk user, empty order (expect unsupported type, unknown user, order_id is required)' as check,
       public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-8', '1557194487352053761', 'r', 10, 7) ->> 'msg' as t,
       public.sud_apply_score('zzz', 'ord-9', '1557194487352053761', 'r', 10, 1) ->> 'msg' as u,
       public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', '', '1557194487352053761', 'r', 10, 1) ->> 'msg' as o;
select '6k the ledger says what happened (expect game_bet -100, game_win 500)' as check,
       (select amount from public.wallet_ledger where kind = 'game_bet' and note = 'sud:1557194487352053761' limit 1) as bet,
       (select amount from public.wallet_ledger where kind = 'game_win' and note = 'sud:1557194487352053761' limit 1) as win;
select '6l refusals are kept for a human (expect >= 4 rejected rows)' as check, count(*) as n from public.game_transactions where status = 'rejected' and transaction_id like 'sud:%';
-- daily limits
update public.game_config set daily_loss_limit = 200 where id;
select '6m the daily loss limit stops a bet that would pass it (net loss now -400: wins exceed bets, so a 150 bet is fine; then 5 x 100 bets) (expect 0)' as check,
       (public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-10', '1557194487352053761', 'round-5', 150, 1) ->> 'code')::int as code;
update public.game_config set daily_loss_limit = 100 where id;
select '6n ... and with a 100 limit a further bet is refused (expect daily limit reached)' as check,
       public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-11', '1557194487352053761', 'round-6', 500, 1) ->> 'msg' as msg;
update public.game_config set daily_loss_limit = 0 where id;
-- paused: bets refused, a win still paid
select public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-12', '1557194487352053761', 'round-7', 100, 1);
select pg_temp.set_flags('{"sud_coin_games_enabled": false}');
select '6o switched off: a new bet is refused (expect games are paused)' as check, public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-13', '1557194487352053761', 'round-8', 100, 1) ->> 'msg' as msg;
select '6p ... but the win of a bet placed before is still paid (expect 0)' as check, (public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'ord-14', '1557194487352053761', 'round-7', 200, 2) ->> 'code')::int as code;

-- 7. the event log
select public.sud_log_event('game_settle', 'b1000000-0000-0000-0000-0000000000b2', '1468180338417074177', 'room-1', 'round-1', '{"a":1}'::jsonb);
select public.sud_log_event('x', null, null, null, null, to_jsonb(repeat('z', 9000)));
select '7 events are logged and an oversized payload is replaced (expect 2, 1)' as check, count(*) as n, count(*) filter (where payload ? 'truncated') as truncated from public.sud_events;

-- 8. permissions
select '8 nothing money-related is callable by app users or anon (expect all f)' as check,
  has_function_privilege('anon', 'public.sud_apply_score(text,text,text,text,bigint,integer)', 'execute') as a1,
  has_function_privilege('authenticated', 'public.sud_apply_score(text,text,text,text,bigint,integer)', 'execute') as a2,
  has_function_privilege('authenticated', 'public.sud_user_info(text)', 'execute') as a3,
  has_function_privilege('authenticated', 'public.sud_log_event(text,text,text,text,text,jsonb)', 'execute') as a4,
  has_function_privilege('anon', 'public.sud_launch_check(bigint,text)', 'execute') as a5,
  has_function_privilege('anon', 'public.admin_save_sud_game(text,text,numeric,boolean,text,text,integer,integer)', 'execute') as a6;
select '8b a signed-in user can launch (expect t)' as check, has_function_privilege('authenticated', 'public.sud_launch_check(bigint,text)', 'execute') as ok;
