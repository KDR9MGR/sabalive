-- Alpha pass, round 2: live-feed realtime, per-user stream likes, block &
-- report. (KYC submission uses the existing kyc_verifications self-insert
-- policy — no change needed there.)

-- ─────────────────────────── live_streams on the realtime publication
do $$
begin
  if not exists (select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'live_streams') then
    execute 'alter publication supabase_realtime add table public.live_streams';
  end if;
end $$;

-- ─────────────────────────── stream likes (per user, drives like_count)
create table public.stream_likes (
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (live_stream_id, profile_id)
);

alter table public.stream_likes enable row level security;

create policy "Stream likes are public"
  on public.stream_likes for select using (true);
create policy "Users like as themselves"
  on public.stream_likes for insert with check (profile_id = auth.uid());
create policy "Users unlike as themselves"
  on public.stream_likes for delete using (profile_id = auth.uid());

create function public.handle_stream_like_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.live_streams set like_count = like_count + 1
      where id = new.live_stream_id;
  elsif tg_op = 'DELETE' then
    update public.live_streams set like_count = greatest(like_count - 1, 0)
      where id = old.live_stream_id;
  end if;
  return null;
end;
$$;

create trigger stream_likes_after_change
  after insert or delete on public.stream_likes
  for each row execute function public.handle_stream_like_change();

-- ─────────────────────────── blocks
create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

alter table public.blocks enable row level security;

create policy "See your own block list"
  on public.blocks for select using (blocker_id = auth.uid());
create policy "Block as yourself"
  on public.blocks for insert with check (blocker_id = auth.uid());
create policy "Unblock as yourself"
  on public.blocks for delete using (blocker_id = auth.uid());

-- ─────────────────────────── user reports (moderation queue)
create table public.user_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  target_type text not null check (target_type in ('user', 'stream', 'message', 'comment')),
  target_id uuid not null,
  reason text not null,
  note text,
  status text not null default 'open' check (status in ('open', 'reviewing', 'actioned', 'dismissed')),
  created_at timestamptz not null default now()
);

create index user_reports_status_idx on public.user_reports (status, created_at desc);

alter table public.user_reports enable row level security;

create policy "See reports you filed"
  on public.user_reports for select
  using (reporter_id = auth.uid() or public.is_admin_or_above());
create policy "File a report as yourself"
  on public.user_reports for insert with check (reporter_id = auth.uid());
create policy "Admins triage reports"
  on public.user_reports for update using (public.is_admin_or_above());
