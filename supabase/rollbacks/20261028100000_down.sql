-- Down script for supabase/migrations/20261028100000_games_sorting.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Drops the play log, the popularity table, their functions and the job. The apps fall back to "no play counts": the sort "Most played" then keeps the
-- panel's order, and a missing added_at only means "Newest / Oldest" order by id. Cannot be undone by this script: the counts that were collected.
begin;
set local lock_timeout = '5s';

do $$
begin
  perform cron.unschedule('refresh-game-popularity');
exception when others then null;
end $$;
drop function if exists public.refresh_game_popularity();
drop function if exists public.record_game_play(bigint);
drop table if exists public.game_popularity;
drop table if exists public.game_plays;
alter table public.sud_games drop column if exists added_at;
alter table public.merchant_games drop column if exists added_at;

commit;
