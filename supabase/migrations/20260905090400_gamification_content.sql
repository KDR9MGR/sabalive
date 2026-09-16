-- Badges/frames economy, admin-authored content (banners, legal pages,
-- announcements), per-user notifications, and the platform audit trail.

create table public.badges (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  emoji text not null,
  criteria text,
  status text not null default 'active' check (status in ('active', 'inactive')),
  sort_order integer not null default 0
);

create table public.user_badges (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  badge_id uuid not null references public.badges (id) on delete cascade,
  awarded_at timestamptz not null default now(),
  primary key (profile_id, badge_id)
);

create table public.frames (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  emoji text not null,
  unlock_type text not null default 'free' check (unlock_type in ('free', 'level', 'vip', 'coins', 'event')),
  unlock_value integer not null default 0,
  price_coins integer not null default 0,
  status text not null default 'active' check (status in ('active', 'draft')),
  sort_order integer not null default 0
);

create table public.user_frames (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  frame_id uuid not null references public.frames (id) on delete cascade,
  equipped boolean not null default false,
  acquired_at timestamptz not null default now(),
  primary key (profile_id, frame_id)
);

create table public.leaderboard_frames (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  emoji text not null,
  scope text not null default 'global' check (scope in ('global', 'agency', 'regional')),
  period text not null default 'weekly' check (period in ('weekly', 'monthly', 'season')),
  status text not null default 'active' check (status in ('active', 'scheduled'))
);

alter table public.badges enable row level security;
alter table public.user_badges enable row level security;
alter table public.frames enable row level security;
alter table public.user_frames enable row level security;
alter table public.leaderboard_frames enable row level security;

create policy "Active badges are public" on public.badges for select using (status = 'active' or public.is_admin_or_above());
create policy "Admins manage badges" on public.badges for insert with check (public.is_admin_or_above());
create policy "Admins update badges" on public.badges for update using (public.is_admin_or_above());

create policy "Earned badges are publicly viewable" on public.user_badges for select using (true);
create policy "Admins award badges" on public.user_badges for insert with check (public.is_admin_or_above());

create policy "Active frames are public" on public.frames for select using (status = 'active' or public.is_admin_or_above());
create policy "Admins manage frames" on public.frames for insert with check (public.is_admin_or_above());
create policy "Admins update frames" on public.frames for update using (public.is_admin_or_above());

create policy "Owned frames are publicly viewable" on public.user_frames for select using (true);
create policy "Owners equip their own frame" on public.user_frames for update using (profile_id = auth.uid());
create policy "Admins grant frames" on public.user_frames for insert with check (public.is_admin_or_above());

create policy "Active leaderboard frames are public"
  on public.leaderboard_frames for select using (status = 'active' or public.is_admin_or_above());
create policy "Admins manage leaderboard frames"
  on public.leaderboard_frames for insert with check (public.is_admin_or_above());
create policy "Admins update leaderboard frames"
  on public.leaderboard_frames for update using (public.is_admin_or_above());

-- ------------------------------------------------------------------ content
create table public.banners (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  image_url text,
  placement text not null default 'home_top' check (placement in ('home_top', 'live_room', 'wallet', 'explore')),
  starts_at timestamptz,
  ends_at timestamptz,
  status text not null default 'scheduled' check (status in ('active', 'scheduled', 'expired'))
);

create table public.legal_pages (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  slug text not null unique,
  body text not null default '',
  status text not null default 'draft' check (status in ('draft', 'published')),
  updated_at timestamptz not null default now()
);

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null default '',
  audience text not null default 'all' check (audience in ('all', 'hosts', 'agencies', 'sub_admins')),
  channel text not null default 'in_app' check (channel in ('in_app', 'push', 'email')),
  status text not null default 'draft' check (status in ('draft', 'scheduled', 'sent')),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.banners enable row level security;
alter table public.legal_pages enable row level security;
alter table public.announcements enable row level security;

create policy "Active banners are public" on public.banners for select using (status = 'active' or public.is_admin_or_above());
create policy "Admins manage banners" on public.banners for insert with check (public.is_admin_or_above());
create policy "Admins update banners" on public.banners for update using (public.is_admin_or_above());

create policy "Published legal pages are public"
  on public.legal_pages for select using (status = 'published' or public.is_admin_or_above());
create policy "Admins manage legal pages" on public.legal_pages for insert with check (public.is_admin_or_above());
create policy "Admins update legal pages" on public.legal_pages for update using (public.is_admin_or_above());

create policy "Only staff see announcements" on public.announcements for select using (public.is_admin_or_above());
create policy "Admins create announcements" on public.announcements for insert with check (public.is_admin_or_above());
create policy "Admins update announcements" on public.announcements for update using (public.is_admin_or_above());

-- ------------------------------------------------------------- notifications
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null,
  body text not null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create index notifications_profile_idx on public.notifications (profile_id, created_at desc);

alter table public.notifications enable row level security;

create policy "Owners see their own notifications" on public.notifications for select using (profile_id = auth.uid());
create policy "Owners mark their own notifications read"
  on public.notifications for update using (profile_id = auth.uid()) with check (profile_id = auth.uid());
-- No insert policy for authenticated/anon — notifications are created by
-- triggers or Edge Functions running as service_role.

-- New follower notification, as a first concrete example of that pattern.
create function public.notify_new_follower()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.notifications (profile_id, kind, body)
  values (new.followee_id, 'follow', (select name from public.profiles where id = new.follower_id) || ' started following you');
  return new;
end;
$$;

create trigger follows_notify
  after insert on public.follows
  for each row execute function public.notify_new_follower();

-- ------------------------------------------------------------------- audit
create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles (id),
  action text not null,
  target text,
  ip inet,
  severity text not null default 'info' check (severity in ('info', 'warning', 'critical')),
  created_at timestamptz not null default now()
);

alter table public.audit_logs enable row level security;

create policy "Only admins read audit logs" on public.audit_logs for select using (public.is_admin_or_above());
-- No insert policy for authenticated/anon: written only by service-role code
-- (Edge Functions) or trusted triggers, never directly by a client.
