-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/tulasi_games_test.sql
-- Proves (20261013100000): games are off until the flag is on; 18+ / no ghosts; a launch gives a 32-character token whose hash is stored; Tulasi's user
-- lookup; a bet is applied exactly once (a repeat changes nothing); timeouts, the bet cap, daily limits and overdrafts are refused; a win needs a bet and
-- stays under the payout multiple; refused requests are kept as 'rejected'; permissions.
insert into auth.users (id, email) values
  ('a9000000-0000-0000-0000-000000000001', 'adult9@x'),
  ('b9000000-0000-0000-0000-000000000002', 'minor9@x'),
  ('c9000000-0000-0000-0000-000000000003', 'nodob9@x'),
  ('d9000000-0000-0000-0000-000000000004', 'ghost9@x');
update public.profiles set date_of_birth = '1990-05-05', name = 'Adult Nine' where id = 'a9000000-0000-0000-0000-000000000001';
update public.profiles set date_of_birth = (current_date - interval '16 years')::date where id = 'b9000000-0000-0000-0000-000000000002';
update public.profiles set is_ghost = true, date_of_birth = '1990-01-01' where id = 'd9000000-0000-0000-0000-000000000004';
insert into public.wallet_ledger (profile_id, kind, currency, amount, note) values ('a9000000-0000-0000-0000-000000000001', 'grant', 'coins', 10000, 'test funds');

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlerrm like p_expect;
end $$;

-- 1. off by default, then on
select set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-000000000001', false);
select '1 games are off until the flag is on (expect t)' as check, pg_temp.refused('select public.start_game_session(''2883'')', 'Games are not available%') as ok;
select set_config('request.jwt.claim.sub', '', false);   -- the release controls are changed by the server / Super Admin, not by a player
update public.app_config set feature_flags = feature_flags || '{"games_enabled": true}'::jsonb;

-- 2. who may play
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000002', false);
select '2 a minor is refused (expect t)' as check, pg_temp.refused('select public.start_game_session()', 'Games are for people aged 18%') as ok;
select set_config('request.jwt.claim.sub', 'c9000000-0000-0000-0000-000000000003', false);
select '2b no date of birth is refused (expect t)' as check, pg_temp.refused('select public.start_game_session()', 'Add your date of birth%') as ok;
select set_config('request.jwt.claim.sub', 'd9000000-0000-0000-0000-000000000004', false);
select '2c a ghost is refused (expect t)' as check, pg_temp.refused('select public.start_game_session()', 'This account cannot play%') as ok;
select set_config('request.jwt.claim.sub', '', false);
select '2d signed out is refused (expect t)' as check, pg_temp.refused('select public.start_game_session()', 'Sign in to play%') as ok;

-- 3. a launch
select set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-000000000001', false);
create temp table s as select public.start_game_session('2883') as j;
select '3 token is 32 characters, uid is a number (expect 32, t)' as check, length(j ->> 'token') as n, (j ->> 'uid')::bigint >= 10001 as ok from s;
select '3b only the hash is stored (expect 1 row, no plain token)' as check,
       (select count(*) from public.game_sessions) as n,
       not exists (select 1 from public.game_sessions g, s where g.token_hash = s.j ->> 'token') as ok;
create temp table s2 as select public.start_game_session('2883') as j;
select '3c the same person keeps the same uid (expect t)' as check, (s.j ->> 'uid') = (s2.j ->> 'uid') as ok from s, s2;
select set_config('request.jwt.claim.sub', '', false);

-- 4. Tulasi's user lookup
select '4 userInformation (expect true, Adult Nine, 10000)' as check, public.game_get_user(j ->> 'token') ->> 'ok' as ok,
       public.game_get_user(j ->> 'token') ->> 'nickname' as nickname, public.game_get_user(j ->> 'token') ->> 'coin' as coin from s;
select '4b a made-up token is refused (expect false)' as check, public.game_get_user('nonsense') ->> 'ok' as ok;

-- helper to call the balance function with this launch's token
create or replace function pg_temp.apply(p_tx text, p_type int, p_coin bigint, p_game text default 'kingdoms', p_ts_offset bigint default 0, p_end_offset bigint default 10000, p_uid bigint default null)
returns jsonb language sql as $$
  select public.game_apply_balance(
    (select j ->> 'token' from s), coalesce(p_uid, (select (j ->> 'uid')::bigint from s)), p_tx, p_type, p_coin, '2883', p_game,
    (extract(epoch from clock_timestamp()) * 1000)::bigint + p_ts_offset, (extract(epoch from clock_timestamp()) * 1000)::bigint,
    (extract(epoch from clock_timestamp()) * 1000)::bigint + p_end_offset, 'ext', 'bet');
$$;

-- 5. a bet is applied once
select '5 bet 100 (expect true, 9900)' as check, pg_temp.apply('tx1', 0, 100) ->> 'ok' as ok, pg_temp.apply('tx1', 0, 100) ->> 'coin' as coin;
select '5b the repeat changed nothing (expect 9900, 1 bet row)' as check,
       (select coins from public.wallets where profile_id = 'a9000000-0000-0000-0000-000000000001') as coins,
       (select count(*) from public.wallet_ledger where kind = 'game_bet') as bets;
select '5c the repeat is flagged as a repeat (expect true)' as check, pg_temp.apply('tx1', 0, 100) ->> 'repeat' as repeat;

-- 6. refusals
select '6 a request 5 s old (expect false, timeout)' as check, (pg_temp.apply('tx-old', 0, 100, 'kingdoms', -5000) ->> 'msg') as msg;
select '6b after the round ended (expect game timeout)' as check, (pg_temp.apply('tx-late', 0, 100, 'kingdoms', 0, -1) ->> 'msg') as msg;
select '6c wrong uid (expect uid does not match the token)' as check, (pg_temp.apply('tx-uid', 0, 100, 'kingdoms', 0, 10000, 99999999) ->> 'msg') as msg;
select '6d more than the balance (expect insufficient balance)' as check, (pg_temp.apply('tx-big', 0, 50000) ->> 'msg') as msg;
select '6e game coin types are not supported (expect unsupported type)' as check, (pg_temp.apply('tx-gc', 2, 10) ->> 'msg') as msg;
update public.game_config set max_bet = 500;
select '6f above the bet cap (expect bet above the limit)' as check, (pg_temp.apply('tx-cap', 0, 600) ->> 'msg') as msg;
update public.game_config set max_bet = 100000;
select '6g nothing was charged by the refusals (expect 9900)' as check, (select coins from public.wallets where profile_id = 'a9000000-0000-0000-0000-000000000001') as coins;

-- 7. a win
select '7 win 290 after a bet (expect true, 10190)' as check, pg_temp.apply('tx2', 1, 290) ->> 'ok' as ok, pg_temp.apply('tx2', 1, 290) ->> 'coin' as coin;
select '7b the ledger has one bet and one win (expect 1, 1)' as check,
       (select count(*) from public.wallet_ledger where kind = 'game_bet') as bets, (select count(*) from public.wallet_ledger where kind = 'game_win') as wins;
select '7c a win on a game nobody bet on (expect win without a bet)' as check, (pg_temp.apply('tx3', 1, 50, 'lucky99') ->> 'msg') as msg;
update public.game_config set max_payout_multiple = 2;
select '7d a win far above the bets (expect win above the payout limit)' as check, (pg_temp.apply('tx4', 1, 5000) ->> 'msg') as msg;
update public.game_config set max_payout_multiple = 100;
select '7e the refused wins paid nothing (expect 10190)' as check, (select coins from public.wallets where profile_id = 'a9000000-0000-0000-0000-000000000001') as coins;

-- 8. daily limits (net so far: bet 100, won 290 => net win 190)
update public.game_config set daily_win_limit = 150;
select '8 over the daily win limit, new bets stop (expect daily limit reached)' as check, (pg_temp.apply('tx5', 0, 10) ->> 'msg') as msg;
update public.game_config set daily_win_limit = 0, daily_loss_limit = 100;
select '8b loss limit: net is a win, so a small bet is fine (expect true)' as check, pg_temp.apply('tx6', 0, 10) ->> 'ok' as ok;
update public.game_config set daily_loss_limit = 1;
select '8c a bet beyond the loss limit (expect daily limit reached)' as check, (pg_temp.apply('tx7', 0, 1000) ->> 'msg') as msg;
update public.game_config set daily_loss_limit = 0;

-- 9. refused requests are kept
select '9 rejected rows kept (expect at least 8)' as check, count(*) as n from public.game_transactions where status = 'rejected';
select '9b the day totals add up (expect bet 110, won 290)' as check, bet, won from public.game_player_day_totals where profile_id = 'a9000000-0000-0000-0000-000000000001';

-- 10. the switch and expiry
update public.app_config set feature_flags = feature_flags || '{"games_enabled": false}'::jsonb;
select '10 switched off: the lookup refuses (expect false)' as check, public.game_get_user((select j ->> 'token' from s)) ->> 'ok' as ok;
select '10b switched off: a bet is refused and recorded (expect games are paused)' as check, (pg_temp.apply('tx8', 0, 10) ->> 'msg') as msg;
update public.app_config set feature_flags = feature_flags || '{"games_enabled": true}'::jsonb;
update public.game_sessions set expires_at = now() - interval '1 minute';
select '10c an expired launch is refused (expect invalid token)' as check, (pg_temp.apply('tx9', 0, 10) ->> 'msg') as msg;

-- 11. permissions
select '11 anon cannot run the balance function (expect f)' as check, has_function_privilege('anon', 'public.game_apply_balance(text,bigint,text,integer,bigint,text,text,bigint,bigint,bigint,text,text)', 'execute') as ok;
select '11b a signed-in user cannot either (expect f)' as check, has_function_privilege('authenticated', 'public.game_apply_balance(text,bigint,text,integer,bigint,text,text,bigint,bigint,bigint,text,text)', 'execute') as ok;
select '11c nor the user lookup (expect f)' as check, has_function_privilege('authenticated', 'public.game_get_user(text)', 'execute') as ok;
select '11d but a signed-in user can start a game (expect t)' as check, has_function_privilege('authenticated', 'public.start_game_session(text)', 'execute') as ok;
select '11e anon cannot (expect f)' as check, has_function_privilege('anon', 'public.start_game_session(text)', 'execute') as ok;
select '11f the game ledger kinds are accepted, others still are (expect 2 game kinds in the constraint)' as check,
       (select count(*) from regexp_matches(pg_get_constraintdef(oid), 'game_(bet|win)', 'g')) as n
  from pg_constraint where conname = 'wallet_ledger_kind_check' and conrelid = 'public.wallet_ledger'::regclass;
select '11g the old kinds are still in the constraint (expect t)' as check,
       pg_get_constraintdef(oid) like '%gift_sent%' and pg_get_constraintdef(oid) like '%grant_reversal%' and pg_get_constraintdef(oid) like '%store_purchase%' as ok
  from pg_constraint where conname = 'wallet_ledger_kind_check' and conrelid = 'public.wallet_ledger'::regclass;
