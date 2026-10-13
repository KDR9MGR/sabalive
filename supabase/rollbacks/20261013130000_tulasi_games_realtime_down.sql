-- Down script for supabase/migrations/20261013130000_tulasi_games_realtime.sql
begin;
set local lock_timeout = '5s';
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'merchant_games') then
    alter publication supabase_realtime drop table public.merchant_games;
  end if;
end $$;
drop policy if exists "Signed-in users see every game" on public.merchant_games;
create policy "Signed-in users see the enabled games" on public.merchant_games for select to authenticated using (status = 1);
commit;
