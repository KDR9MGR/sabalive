-- Single-row runtime config for the platform: economy rates, limits, a
-- couple of global switches, the brand colour and a free-form feature-flag
-- bag. The sabaliveadmin "Application Configuration" screen reads and
-- writes this; the consumer app can read it too (world-readable).

create table public.app_config (
  id boolean primary key default true check (id),
  coin_to_inr_rate        numeric(10, 4) not null default 1.0,
  diamond_to_inr_rate     numeric(10, 4) not null default 0.60,
  min_recharge_inr        integer not null default 10,
  min_withdrawal_inr      integer not null default 500,
  min_withdrawal_diamonds integer not null default 0,
  platform_fee_percent    numeric(5, 2) not null default 0,
  gst_percent             numeric(5, 2) not null default 18,
  maintenance_mode        boolean not null default false,
  allow_registrations     boolean not null default true,
  brand_color             text not null default '#7c3aed',
  feature_flags           jsonb not null default '{}'::jsonb,
  updated_at              timestamptz not null default now(),
  updated_by              uuid references public.profiles (id)
);

-- the one and only row
insert into public.app_config (id) values (true);

alter table public.app_config enable row level security;

create policy "App config is world-readable"
  on public.app_config for select using (true);
create policy "Admins update app config"
  on public.app_config for update using (public.is_admin_or_above());
-- deliberately no insert / delete policy: the singleton row is seeded here.

create function public.stamp_app_config()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  new.id := true;               -- keep the singleton pinned
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

create trigger app_config_stamp before update on public.app_config
  for each row execute function public.stamp_app_config();
