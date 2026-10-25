-- Down script for supabase/migrations/20261025110000_level_xp_free_edit.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Removes admin_save_track_level_v2. The panel falls back to admin_save_track_level (the strict rule: an XP must stay between its neighbours).
-- Levels that were shifted keep their new XP values; nothing is restored.
begin;
set local lock_timeout = '5s';

drop function if exists public.admin_save_track_level_v2(text, integer, integer, text, boolean);

commit;
