-- Down script for supabase/migrations/20261026110000_sud_games.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Removes the SUD catalogue, its functions, the event log and the daily clean-up job. Coins already moved by SUD coin games stay where they are (they are in
-- wallet_ledger / game_transactions, which this does not touch). Nothing of Tulasi's is affected; the app and panel fall back to "no SUD games".
begin;
set local lock_timeout = '5s';

do $$
begin
  perform cron.unschedule('prune-sud-events');
exception when others then null;
end $$;
drop function if exists public.sud_log_event(text, text, text, text, text, jsonb);
drop table if exists public.sud_events;
drop function if exists public.sud_apply_score(text, text, text, text, bigint, integer);
drop function if exists public.sud_user_info(text);
drop function if exists public.sud_launch_check(bigint, text);
drop function if exists public.admin_set_sud_games_hidden(bigint[], boolean);
drop function if exists public.admin_delete_sud_game(bigint);
drop function if exists public.admin_save_sud_game(text, text, numeric, boolean, text, text, integer, integer);
drop function if exists public._sud_coins_enabled();
drop function if exists public._sud_enabled();
drop table if exists public.sud_games;
drop sequence if exists public.sud_game_id_seq;

commit;
