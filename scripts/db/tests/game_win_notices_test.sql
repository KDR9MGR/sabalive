-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/game_win_notices_test.sql
-- Proves (20261107100000_game_win_notices): a game win of at least 5,000 coins (a Tulasi or a SUD round, written 'pending' and then updated to 'ok') leaves one notice with the
-- winner's name and picture, the game's name and picture and the coins; nothing smaller, no bet, no rejected round, no repeat, no ghost does; old notices are cleared; a notice
-- problem never blocks the payout; signed-in users can read the notices and nobody can write them. Every line ends in ok = t; the last line says ALL PASSED or how many failed.
set time zone 'UTC';
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'winner@x'), ('a2000000-0000-0000-0000-000000000002', 'ghost@x');
set session_replication_role = replica;
update public.profiles set is_ghost = true where id = 'a2000000-0000-0000-0000-000000000002';
set session_replication_role = origin;
update public.profiles set name = 'Winner One', avatar_url = 'https://x/avatar.png' where id = 'a1000000-0000-0000-0000-000000000001';
insert into public.merchant_games (id, name, identification, image_url, status, hidden) values (2840, 'Rocket Star', 'rocket', 'https://x/rocket.png', 1, false);
insert into public.sud_games (id, provider_game_id, name, image_url, uses_coins, status) values (1000001, '9000000000000000002', 'Ludo Master', 'https://x/ludo.png', true, 1);

create temp table r (n serial, check_name text, ok boolean);
grant all on r to authenticated, anon;
grant usage, select on sequence r_n_seq to authenticated, anon;
create function pg_temp.refused(sql text) returns boolean language plpgsql as $$ begin execute sql; return false; exception when others then return true; end $$;

-- a round is written the way both providers do: 'pending', then 'ok'
create function pg_temp.round(tid text, who uuid, gid text, gtype text, typ int, coins bigint, final text default 'ok') returns void language plpgsql as $$
begin
  insert into public.game_transactions (transaction_id, profile_id, game_uid, game_id, game_type, type, coin) values (tid, who, 1001, gid, gtype, typ, coins);
  update public.game_transactions set status = final where transaction_id = tid;
end $$;

insert into r(check_name, ok) select '1 the threshold lives in one function and is 5,000', public.game_win_notice_min_coins() = 5000;

select pg_temp.round('t1', 'a1000000-0000-0000-0000-000000000001', '2840', 'rocket', 1, 5000);
insert into r(check_name, ok) select '2 a Tulasi win of exactly 5,000 leaves one notice with the winner, the game and the coins',
  (select count(*) from public.game_win_notices) = 1
  and (select (winner_name, winner_avatar_url, game_name, game_image_url, coins, profile_id)::text from public.game_win_notices)
      = '("Winner One",https://x/avatar.png,"Rocket Star",https://x/rocket.png,5000,a1000000-0000-0000-0000-000000000001)';

select pg_temp.round('t2', 'a1000000-0000-0000-0000-000000000001', '2840', 'rocket', 1, 4999);
insert into r(check_name, ok) select '3 a win of 4,999 leaves nothing', (select count(*) from public.game_win_notices) = 1;

select pg_temp.round('t3', 'a1000000-0000-0000-0000-000000000001', '2840', 'rocket', 0, 90000);
insert into r(check_name, ok) select '4 a BET of any size leaves nothing', (select count(*) from public.game_win_notices) = 1;

select pg_temp.round('t4', 'a1000000-0000-0000-0000-000000000001', '2840', 'rocket', 1, 8000, 'rejected');
insert into r(check_name, ok) select '5 a rejected round leaves nothing', (select count(*) from public.game_win_notices) = 1;

update public.game_transactions set status = 'ok', reason = 'again' where transaction_id = 't1';
insert into r(check_name, ok) select '6 saving an already accepted win again (a repeat) does not add a second notice', (select count(*) from public.game_win_notices) = 1;

select pg_temp.round('t5', 'a1000000-0000-0000-0000-000000000001', '9000000000000000002', 'sud:9000000000000000002', 1, 12345);
insert into r(check_name, ok) select '7 a SUD win reads its game from the SUD list',
  (select count(*) from public.game_win_notices) = 2
  and (select game_name from public.game_win_notices where coins = 12345) = 'Ludo Master'
  and (select game_image_url from public.game_win_notices where coins = 12345) = 'https://x/ludo.png';

select pg_temp.round('t6', 'a2000000-0000-0000-0000-000000000002', '2840', 'rocket', 1, 50000);
insert into r(check_name, ok) select '8 a ghost (monitoring) account never shows up', (select count(*) from public.game_win_notices) = 2;

select pg_temp.round('t7', 'a1000000-0000-0000-0000-000000000001', '123456', 'rocket', 1, 7000);
insert into r(check_name, ok) select '9 a win in a game the lists do not know still shows (the game name is just empty)',
  (select count(*) from public.game_win_notices where coins = 7000 and game_name is null) = 1;

-- old notices go away with the next one
update public.game_win_notices set created_at = now() - interval '3 days' where coins = 5000;
select pg_temp.round('t8', 'a1000000-0000-0000-0000-000000000001', '2840', 'rocket', 1, 6000);
insert into r(check_name, ok) select '10 notices older than 2 days are removed by the next one',
  (select count(*) from public.game_win_notices where coins = 5000) = 0 and (select count(*) from public.game_win_notices where coins = 6000) = 1;

-- a notice that cannot be written never blocks the payout
alter table public.game_win_notices add constraint zz_always_fails check (coins < 0) not valid;   -- not valid: the rows already there are left alone, every NEW row is refused
select pg_temp.round('t9', 'a1000000-0000-0000-0000-000000000001', '2840', 'rocket', 1, 9999);
insert into r(check_name, ok) select '11 when the notice cannot be written the game transaction is still accepted',
  (select status from public.game_transactions where transaction_id = 't9') = 'ok' and (select count(*) from public.game_win_notices where coins = 9999) = 0;
alter table public.game_win_notices drop constraint zz_always_fails;

-- who can do what
set role authenticated;
insert into r(check_name, ok) select '12 a signed-in user can read the notices', (select count(*) from public.game_win_notices) >= 1;
insert into r(check_name, ok) select '13 nobody from the app can write, change or delete one',
  pg_temp.refused($q$insert into public.game_win_notices (profile_id, winner_name, coins) values ('a1000000-0000-0000-0000-000000000001', 'x', 5000)$q$)
  and pg_temp.refused($q$update public.game_win_notices set coins = 1$q$)
  and pg_temp.refused($q$delete from public.game_win_notices$q$);
reset role;
set role anon;
insert into r(check_name, ok) select '14 a signed-out visitor cannot read them', pg_temp.refused($q$select * from public.game_win_notices$q$);
reset role;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
