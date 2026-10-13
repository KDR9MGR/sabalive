-- Down script for supabase/migrations/20261013110000_tulasi_game_list.sql
-- Applied BY HAND only. Removes the game list (it is rebuilt by the platform's next updateGameList / the dashboard's Sync Game List).
begin;
set local lock_timeout = '5s';
drop function if exists public.game_sync_list(jsonb);
drop table if exists public.merchant_games;
commit;
