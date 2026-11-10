-- Down script for supabase/migrations/20261110100000_admin_game_reports.sql: the panel falls back to its old direct reads (slow, but they work).
begin;
set local lock_timeout = '5s';
drop function if exists public.admin_game_day_totals(integer);
drop function if exists public.admin_game_winner_gifting(integer);
drop function if exists public.admin_game_host_inflow(integer);
drop function if exists public.admin_game_transactions(integer);
commit;
