-- Down script for supabase/migrations/20261013120000_tulasi_game_monitoring.sql (views only, no data).
begin;
set local lock_timeout = '5s';
drop view if exists public.game_host_inflow;
drop view if exists public.game_winner_gifting;
commit;
