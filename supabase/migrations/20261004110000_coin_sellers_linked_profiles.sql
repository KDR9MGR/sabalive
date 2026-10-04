-- Offline coin sellers are managed from the Master panel and can be linked to an
-- app user, so the app shows their real profile (photo, name, app ID, level)
-- next to the WhatsApp button. A seller with no linked user still works exactly
-- as before.
alter table public.offline_coin_sellers
  add column if not exists profile_id uuid references public.profiles (id) on delete set null;
create index if not exists offline_coin_sellers_profile_idx on public.offline_coin_sellers (profile_id);

-- staff see inactive sellers too, and manage the list
create policy "Staff see every offline seller"
  on public.offline_coin_sellers for select using (public.is_admin_or_above());
create policy "Staff add offline sellers"
  on public.offline_coin_sellers for insert with check (public.is_admin_or_above());
create policy "Staff edit offline sellers"
  on public.offline_coin_sellers for update using (public.is_admin_or_above());
create policy "Staff remove offline sellers"
  on public.offline_coin_sellers for delete using (public.is_admin_or_above());

alter publication supabase_realtime add table public.offline_coin_sellers;
