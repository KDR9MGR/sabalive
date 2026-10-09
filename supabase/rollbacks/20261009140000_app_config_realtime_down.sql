-- Down script for supabase/migrations/20261009140000_app_config_realtime.sql
-- Applied BY HAND only. Stops Realtime from announcing app_config changes (apps then pick them up when they
-- come back to the foreground or restart).
do $$
begin
  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_config'
  ) then
    alter publication supabase_realtime drop table public.app_config;
  end if;
end
$$;
