-- How long each home-screen banner stays before the carousel slides to the
-- next one. A one-row settings table (not app_config) so Master can change it
-- without also being able to touch the app's theme colours, which stay
-- Super-Admin-only. Read by the app; edited from the panel's Banners page.
create table public.banner_settings (
  id boolean primary key default true check (id),
  slide_interval_seconds integer not null default 20
    check (slide_interval_seconds between 3 and 600),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id)
);

insert into public.banner_settings (id) values (true);

alter table public.banner_settings enable row level security;

create policy "Banner settings are public"
  on public.banner_settings for select using (true);

-- Master (admin) and Super Admin; no insert/delete — it is a single fixed row.
create policy "Admins change banner settings"
  on public.banner_settings for update
  using (public.is_admin_or_above())
  with check (public.is_admin_or_above());
