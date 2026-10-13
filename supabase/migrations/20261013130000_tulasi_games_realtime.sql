-- Tulasi games, part 4: changes made in the Tulasi panel reach open apps at once.
--
-- The platform pushes its game list to us (updateGameList) when someone presses "Sync Game List" in its panel; the Edge Function stores it in
-- merchant_games. For the app to react the moment that lands, merchant_games joins the Realtime publication, and the read policy lets every
-- signed-in user see every row: Realtime only delivers an update the subscriber is allowed to read, and a game that was just DISABLED
-- (status 0) would otherwise vanish silently from the "enabled only" policy instead of reaching the app as a change. The rows hold nothing
-- private (a name, a picture, a path). The app still shows only status 1.
-- Additive: one table in the publication and one policy replaced. Rollback: supabase/rollbacks/20261013130000_tulasi_games_realtime_down.sql.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'merchant_games'
  ) then
    alter publication supabase_realtime add table public.merchant_games;
  end if;
end $$;

drop policy if exists "Signed-in users see the enabled games" on public.merchant_games;
drop policy if exists "Signed-in users see every game" on public.merchant_games;
create policy "Signed-in users see every game" on public.merchant_games for select to authenticated using (true);
