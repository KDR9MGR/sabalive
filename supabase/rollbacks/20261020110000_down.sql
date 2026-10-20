-- Down script for supabase/migrations/20261020110000_video_live_warning.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- The saved switch and text are lost (the apps go back to showing the built-in warning, which is what they do while the columns are
-- missing). Nothing else reads the columns: the panel's Live welcome section shows a message while they are missing, and the apps fail open.
begin;
set local lock_timeout = '5s';

alter table public.app_config drop constraint if exists app_config_video_warning_text_check;
alter table public.app_config drop column if exists video_warning_text;
alter table public.app_config drop column if exists video_warning_enabled;

commit;
