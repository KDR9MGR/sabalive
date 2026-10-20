-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/video_live_warning_rollback_test.sql
-- Proves supabase/rollbacks/20261020110000_down.sql: after it the columns and the check are gone and nothing else on app_config moved
-- (the PK look column stays); a second rollback is harmless; applying the migration again afterwards works.

update public.app_config set video_warning_enabled = false, video_warning_text = 'x', pk_theme = '{"mine":"#00ff00"}';
\i supabase/rollbacks/20261020110000_down.sql
select '1 the columns are gone (expect 0)' as check, count(*) as n from information_schema.columns
  where table_schema = 'public' and table_name = 'app_config' and column_name in ('video_warning_enabled', 'video_warning_text');
select '1 the check is gone (expect 0)' as check, count(*) as n from pg_constraint where conname = 'app_config_video_warning_text_check';
select '2 the PK look column and its value survive (expect 1)' as check, count(*) as n from public.app_config where pk_theme is not null;
select '2 the branding is untouched (expect #7c3aed, Poppins)' as check, brand_color, font_family from public.app_config;
\i supabase/rollbacks/20261020110000_down.sql
select '3 a second rollback is harmless (expect 0)' as check, count(*) as n from information_schema.columns
  where table_schema = 'public' and table_name = 'app_config' and column_name like 'video_warning%';
\i supabase/migrations/20261020110000_video_live_warning.sql
select '4 re-applied: back, ON, no text (expect 2, true, true)' as check,
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'app_config' and column_name like 'video_warning%') as columns,
  (select video_warning_enabled from public.app_config) as enabled, (select video_warning_text is null from public.app_config) as no_text;
