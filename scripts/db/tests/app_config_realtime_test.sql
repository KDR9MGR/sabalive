-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/app_config_realtime_test.sql
select '1 app_config is announced by Realtime (expect 1)' as check, count(*) as n
  from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_config';
