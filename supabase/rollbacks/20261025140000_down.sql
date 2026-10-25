-- Down script for supabase/migrations/20261025140000_level_xp_any_value.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Removes admin_save_track_level_v3. The panel falls back to admin_save_track_level_v2 (a level must stay below the next, or the later levels move up, up to
-- 2,000,000,000 XP). Levels already saved with out-of-order numbers keep them: nothing is rewritten, and a person's level is still the highest level whose
-- XP they reached.
begin;
set local lock_timeout = '5s';

drop function if exists public.admin_save_track_level_v3(text, integer, integer, text);

commit;
