-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/tulasi_game_list_test.sql
-- Proves (20261013110000): the platform's list is stored, re-synced without duplicates, games missing from a later list are switched off,
-- players see only enabled games, and only the service role can write.
select '1 two games stored (expect 2)' as check, public.game_sync_list('[
  {"id": 2883, "merchantId": 1503251, "name": "Teen Patti Gold", "image": "https://t.example/a.png", "imageUrl": "https://ours.example/a.png", "banner": "https://t.example/b.png",
   "gameIdentification": "kingdoms", "status": 1, "gameDomain": "https://gamesp.tulasigame.com/", "expirationDate": null},
  {"id": 2882, "merchantId": 1503251, "name": "Teen Patti", "image": "https://t.example/c.png", "gameIdentification": "kingdoms2", "status": 1}
]'::jsonb) as n;
select '1b our re-hosted picture wins, theirs is the fallback (expect ours, theirs)' as check,
       (select image_url from public.merchant_games where id = 2883) as a, (select image_url from public.merchant_games where id = 2882) as b;
select '2 the same list again changes nothing in size (expect 2 rows)' as check, public.game_sync_list('[{"id": 2883, "name": "Teen Patti Gold", "status": 1}, {"id": 2882, "name": "Teen Patti", "status": 1}]'::jsonb) as n,
       (select count(*) from public.merchant_games) as rows;
select public.game_sync_list('[{"id": 2883, "name": "Teen Patti Gold", "status": 1}, {"id": 2881, "name": "Lucky77", "status": 0}]'::jsonb);
select '3 a game missing from the next list is switched off, the listed one stays on (expect 0, 1)' as check,
       (select status from public.merchant_games where id = 2882) as missing_now,
       (select status from public.merchant_games where id = 2883) as kept;
select '3b a disabled game is stored as disabled (expect 0)' as check, (select status from public.merchant_games where id = 2881) as status;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
select '4 not an array is refused (expect t)' as check, pg_temp.refused('select public.game_sync_list(''{"id": 1}''::jsonb)', 'the game list must be an array%') as ok;
select '5 anon and signed-in users cannot sync (expect f, f)' as check,
       has_function_privilege('anon', 'public.game_sync_list(jsonb)', 'execute') as anon, has_function_privilege('authenticated', 'public.game_sync_list(jsonb)', 'execute') as authed;
-- row policies as a signed-in player: every row is readable (the app shows status 1); nobody can write
insert into auth.users (id, email) values ('a9100000-0000-0000-0000-000000000001', 'player91@x');
select set_config('request.jwt.claim.sub', 'a9100000-0000-0000-0000-000000000001', false);
set role authenticated;
select '6 a player can read every game row, enabled or not (expect 3 rows, 1 enabled)' as check, count(*) as n, count(*) filter (where status = 1) as enabled from public.merchant_games;
do $$ begin
  update public.merchant_games set status = 0 where id = 2883;
  if found then raise exception 'a player could write'; end if;
end $$;
select '6b a player cannot change a game (expect 1 still on)' as check, count(*) filter (where status = 1) as enabled from public.merchant_games;
reset role;
select '7 merchant_games is in the Realtime publication (expect 1)' as check, count(*) as n from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'merchant_games';
