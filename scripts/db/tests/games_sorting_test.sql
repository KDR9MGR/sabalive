-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/games_sorting_test.sql
-- Proves migration 20261028100000: added_at stays put on a sync / a save, record_game_play counts only real, visible games once a minute for a person, a ghost
-- is never counted, no client can read game_plays, and the popularity table is rebuilt from the last 14 days.
-- Every line prints "<what> (expect X)" and the result: compare them by eye.

create or replace function pg_temp.raises(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'NOT raised';
exception when others then
  return 'raised: ' || sqlerrm;
end;
$$;

insert into auth.users (id, email) values
  ('a3000001-0000-0000-0000-000000000001', 'p1@x'), ('a3000002-0000-0000-0000-000000000001', 'p2@x'), ('a3000003-0000-0000-0000-000000000001', 'ghost@x');
update public.profiles set is_ghost = true where id = 'a3000003-0000-0000-0000-000000000001';

-- a Tulasi game (id 2883), a hidden one (2884), a switched-off one (2885) and two SUD games (1000001 shown, 1000002 hidden)
insert into public.merchant_games (id, name, identification, status, hidden) values
  (2883, 'Teen Patti Gold', 'kingdoms', 1, false), (2884, 'Hidden', 'h', 1, true), (2885, 'Off', 'o', 0, false);
insert into public.sud_games (id, provider_game_id, name, status, hidden) values
  (1000001, '1900379203401408513', 'Pirate Fishing', 1, false), (1000002, '1900380052055908354', 'Fruit Party', 1, true);

-- 0. added_at
select '0 every game has a time it was added (expect 5)' as check, (select count(*) from public.merchant_games where added_at is not null) + (select count(*) from public.sud_games where added_at is not null) as n;
update public.merchant_games set added_at = '2026-01-01 00:00:00+00' where id = 2883;
select public.game_sync_list('[{"id": 2883, "name": "Teen Patti Gold (renamed)", "gameIdentification": "kingdoms", "status": 1}]'::jsonb);
select '0 a Tulasi sync keeps added_at (expect 2026-01-01 00:00:00+00)' as check, added_at, name from public.merchant_games where id = 2883;

-- 1. record_game_play
select set_config('request.jwt.claim.sub', 'a3000001-0000-0000-0000-000000000001', false);
select public.record_game_play(2883);
select '1 a shown Tulasi game is counted (expect 1)' as check, count(*) as n from public.game_plays where game_id = 2883;
select public.record_game_play(2883);
select '1 the same person again within a minute counts once (expect 1)' as check, count(*) as n from public.game_plays where game_id = 2883;
select public.record_game_play(1000001);
select '1 a shown SUD game is counted (expect 1)' as check, count(*) as n from public.game_plays where game_id = 1000001;
select public.record_game_play(2884); select public.record_game_play(2885); select public.record_game_play(1000002); select public.record_game_play(99);
select '1 hidden, switched-off and unknown games are not counted (expect 0)' as check, count(*) as n from public.game_plays where game_id in (2884, 2885, 1000002, 99);
select public.record_game_play(null);
select '1 a null game is ignored without an error (expect 2 rows in all)' as check, count(*) as n from public.game_plays;
-- the same person, a minute later
update public.game_plays set created_at = now() - interval '2 minutes' where game_id = 2883;
select public.record_game_play(2883);
select '1 a minute later it counts again (expect 2)' as check, count(*) as n from public.game_plays where game_id = 2883;
-- another person
select set_config('request.jwt.claim.sub', 'a3000002-0000-0000-0000-000000000001', false);
select public.record_game_play(2883);
select '1 another person counts too (expect 3)' as check, count(*) as n from public.game_plays where game_id = 2883;
-- a ghost, and nobody signed in
select set_config('request.jwt.claim.sub', 'a3000003-0000-0000-0000-000000000001', false);
select public.record_game_play(2883);
select '1 a ghost is never counted (expect 3)' as check, count(*) as n from public.game_plays where game_id = 2883;
select set_config('request.jwt.claim.sub', '', false);
select public.record_game_play(2883);
select '1 nobody signed in: nothing, no error (expect 3)' as check, count(*) as n from public.game_plays where game_id = 2883;

-- 2. the popularity table
select refresh_result.* from (select public.refresh_game_popularity()) refresh_result;
select '2 plays and different people over the window (expect 2883: 3 plays, 2 players)' as check, game_id, plays, players from public.game_popularity where game_id = 2883;
select '2 the other counted game (expect 1000001: 1 play, 1 player)' as check, game_id, plays, players from public.game_popularity where game_id = 1000001;
select '2 only counted games appear (expect 2 rows)' as check, count(*) as n from public.game_popularity;
-- old plays fall out of the window, then out of the table
update public.game_plays set created_at = now() - interval '20 days' where game_id = 2883 and profile_id = 'a3000002-0000-0000-0000-000000000001';
update public.game_plays set created_at = now() - interval '40 days' where game_id = 1000001;
select public.refresh_game_popularity();
select '2 a 20-day-old play no longer counts (expect 2883: 2 plays, 1 player)' as check, game_id, plays, players from public.game_popularity where game_id = 2883;
select '2 a 40-day-old play is deleted and its game leaves the table (expect 0 rows for 1000001)' as check, (select count(*) from public.game_plays where game_id = 1000001) + (select count(*) from public.game_popularity where game_id = 1000001) as n;

-- 3. who can see what
select '3 anon cannot call record_game_play (expect 0)' as check, count(*) as n from information_schema.routine_privileges
  where routine_schema = 'public' and grantee = 'anon' and routine_name in ('record_game_play', 'refresh_game_popularity');
select '3 nobody but the job can refresh (expect 0)' as check, count(*) as n from information_schema.routine_privileges
  where routine_schema = 'public' and grantee in ('authenticated', 'anon', 'public') and routine_name = 'refresh_game_popularity';
select '3 game_plays has no policy: no client can read it (expect 0)' as check, count(*) as n from pg_policies where tablename = 'game_plays';
select '3 game_popularity can be read by signed-in people (expect 1 policy)' as check, count(*) as n from pg_policies where tablename = 'game_popularity';
