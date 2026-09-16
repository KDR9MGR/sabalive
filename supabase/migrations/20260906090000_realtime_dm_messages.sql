-- Chat threads need live delivery: put dm_messages on the supabase_realtime
-- publication so the app's Postgres Changes subscription fires on INSERT.
-- Guarded so a re-run (or a project where it's already published) is a no-op.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'dm_messages'
  ) then
    execute 'alter publication supabase_realtime add table public.dm_messages';
  end if;
end $$;
