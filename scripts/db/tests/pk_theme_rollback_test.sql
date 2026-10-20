-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/pk_theme_rollback_test.sql
-- Proves supabase/rollbacks/20261020100000_down.sql: after it the column and its check are gone and nothing else on app_config moved;
-- applying the migration again afterwards works (so a rollback can be retried forward).

update public.app_config set pk_theme = '{"mine":"#00ff00"}';
select '1 before: the column holds a value (expect 1)' as check, count(*) as n from public.app_config where pk_theme is not null;

\i supabase/rollbacks/20261020100000_down.sql

select '2 the column is gone (expect 0)' as check, count(*) as n from information_schema.columns where table_schema = 'public' and table_name = 'app_config' and column_name = 'pk_theme';
select '2 its check is gone (expect 0)' as check, count(*) as n from pg_constraint where conname = 'app_config_pk_theme_check';
select '3 the branding settings are untouched (expect #7c3aed, Poppins)' as check, brand_color, font_family from public.app_config;
select '3 the singleton row is still there (expect 1)' as check, count(*) as n from public.app_config;
select '3 other app_config checks survive (expect 1)' as check, count(*) as n from pg_constraint where conname = 'app_config_min_version_check';

-- run the down script a second time: it must not fail
\i supabase/rollbacks/20261020100000_down.sql
select '4 a second rollback is harmless (expect 0)' as check, count(*) as n from information_schema.columns where table_schema = 'public' and table_name = 'app_config' and column_name = 'pk_theme';

-- and forward again
\i supabase/migrations/20261020100000_pk_theme.sql
select '5 re-applied: the column is back and empty (expect 1, true)' as check,
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'app_config' and column_name = 'pk_theme') as columns,
  (select pk_theme is null from public.app_config) as empty;
update public.app_config set pk_theme = '{"lose_style":"emoji"}';
select '5 and it works again (expect emoji)' as check, pk_theme ->> 'lose_style' as lose_style from public.app_config;
