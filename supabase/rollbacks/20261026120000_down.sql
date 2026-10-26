-- Down script for supabase/migrations/20261026120000_diamond_reset.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Removes the diamond reset functions and the run log. Cannot be undone by this script: diamonds a reset already removed stay removed (the negative
-- 'grant_reversal' ledger rows are history and are kept; to give them back, use the panel's Undo BEFORE running this, or credit them by hand from those rows,
-- reference_table 'diamond_reset_runs'). Nothing the apps call is affected.
begin;
set local lock_timeout = '5s';

drop function if exists public.admin_undo_diamond_reset(uuid, text);
drop function if exists public.admin_reset_diamonds(text, text, text);
drop function if exists public.admin_diamond_reset_preview(text);
drop function if exists public._diamond_reset_plan(text, text);
drop function if exists public._diamond_reset_actor_ok();
drop table if exists public.diamond_reset_runs;

commit;
