-- Branding (colours, font) and the release controls live in the single app_config row. The app subscribes to
-- changes of that row so a recolour made in the panel reaches running apps at once, but the table was never in
-- the Realtime publication, so no change was ever delivered: apps only noticed on their next launch.
-- (They also re-read it when they return to the foreground, which is the safety net.)
--
-- Additive: one table added to the publication. A save in the panel now sends one small event per connected app.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_config'
  ) then
    alter publication supabase_realtime add table public.app_config;
  end if;
end
$$;
