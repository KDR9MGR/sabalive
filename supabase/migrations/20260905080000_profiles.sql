-- Profiles: one row per auth.users, mirrors lib/data/models.dart AppUser.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null default 'New Star',
  username text not null unique,
  bio text not null default '',
  location text not null default 'India',
  avatar_url text,
  level integer not null default 1,
  followers_count integer not null default 0,
  following_count integer not null default 0,
  fans_count integer not null default 0,
  is_live boolean not null default false,
  is_host boolean not null default false,
  verified boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'Public profile data for each authenticated user; counters are denormalized and kept in sync by triggers added alongside the tables that drive them (follows, live_streams, etc).';

create index profiles_username_idx on public.profiles (lower(username));

alter table public.profiles enable row level security;

-- Profiles are public read (social app: browsing other users, followers lists, live host cards).
create policy "Profiles are viewable by everyone"
  on public.profiles for select
  using (true);

-- Only the owning user may change their own profile, and never their own counters/verified flag
-- (those are maintained server-side by triggers/Edge Functions, not client writes).
create policy "Users can update their own profile"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name, username)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', 'New Star'),
    coalesce(new.raw_user_meta_data ->> 'username', 'user_' || substr(new.id::text, 1, 8))
  );
  return new;
end;
$$;

comment on function public.handle_new_user is 'Creates a profiles row whenever a new auth.users row is inserted (sign up via email, phone OTP, or social).';

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();
