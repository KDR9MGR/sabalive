-- Follow graph and everything a live room needs: streams, viewer presence,
-- in-room chat, go-live/feature/PK approval requests, and PK battle pairing.

create table public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

alter table public.follows enable row level security;

create policy "Follow graph is public"
  on public.follows for select using (true);
create policy "Users follow as themselves"
  on public.follows for insert with check (follower_id = auth.uid());
create policy "Users unfollow as themselves"
  on public.follows for delete using (follower_id = auth.uid());

create function public.handle_follow_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.profiles set following_count = following_count + 1 where id = new.follower_id;
    update public.profiles set followers_count = followers_count + 1 where id = new.followee_id;
  elsif tg_op = 'DELETE' then
    update public.profiles set following_count = greatest(following_count - 1, 0) where id = old.follower_id;
    update public.profiles set followers_count = greatest(followers_count - 1, 0) where id = old.followee_id;
  end if;
  return null;
end;
$$;

create trigger follows_after_change
  after insert or delete on public.follows
  for each row execute function public.handle_follow_change();

-- ------------------------------------------------------------- live streams
-- The Agora channel name is simply the stream's own id (cast to text) — no
-- separate column needed, keeps client and server trivially in sync.
create table public.live_streams (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles (id),
  title text not null,
  category text not null default 'Chatting',
  status text not null default 'live' check (status in ('scheduled', 'live', 'ended')),
  is_pk boolean not null default false,
  viewer_count integer not null default 0,
  like_count integer not null default 0,
  gift_coin_total integer not null default 0,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create index live_streams_status_idx on public.live_streams (status) where status = 'live';
create index live_streams_host_idx on public.live_streams (host_id);

alter table public.live_streams enable row level security;

create policy "Live streams are publicly viewable"
  on public.live_streams for select using (true);
create policy "Hosts start their own stream"
  on public.live_streams for insert
  with check (
    host_id = auth.uid()
    and exists (select 1 from public.profiles where id = auth.uid() and is_host)
  );
create policy "Hosts and staff update a stream"
  on public.live_streams for update
  using (host_id = auth.uid() or public.is_admin_or_above());

-- gift_coin_total is only ever moved by send_gift() (see economy migration).
revoke update on public.live_streams from authenticated;
grant update (title, status, viewer_count, like_count, ended_at) on public.live_streams to authenticated;

create table public.live_stream_viewers (
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  viewer_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (live_stream_id, viewer_id, joined_at)
);

alter table public.live_stream_viewers enable row level security;

create policy "Hosts and staff see their viewer log"
  on public.live_stream_viewers for select
  using (
    viewer_id = auth.uid()
    or public.is_admin_or_above()
    or exists (select 1 from public.live_streams s where s.id = live_stream_id and s.host_id = auth.uid())
  );
create policy "Viewers log their own join"
  on public.live_stream_viewers for insert with check (viewer_id = auth.uid());
create policy "Viewers log their own leave"
  on public.live_stream_viewers for update using (viewer_id = auth.uid());

create table public.live_chat_messages (
  id bigint generated always as identity primary key,
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  sender_id uuid not null references public.profiles (id),
  body text not null,
  kind text not null default 'text' check (kind in ('text', 'gift', 'system')),
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);

create index live_chat_messages_stream_idx on public.live_chat_messages (live_stream_id, created_at desc);

alter table public.live_chat_messages enable row level security;

create policy "Live chat is publicly viewable"
  on public.live_chat_messages for select using (true);
create policy "Signed-in users chat as themselves"
  on public.live_chat_messages for insert with check (sender_id = auth.uid() and kind = 'text');

-- ------------------------------------------------------------ live requests
create table public.live_requests (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles (id),
  type text not null check (type in ('go_live_approval', 'feature_request', 'event_slot', 'pk_battle', 'verification')),
  priority text not null default 'medium' check (priority in ('low', 'medium', 'high')),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  notes text,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.live_requests enable row level security;

create policy "Hosts and staff see relevant requests"
  on public.live_requests for select
  using (host_id = auth.uid() or public.is_admin_or_above());
create policy "Hosts file their own requests"
  on public.live_requests for insert with check (host_id = auth.uid());
create policy "Admins review requests"
  on public.live_requests for update using (public.is_admin_or_above());

create table public.pk_battles (
  id uuid primary key default gen_random_uuid(),
  stream_a_id uuid not null references public.live_streams (id),
  stream_b_id uuid not null references public.live_streams (id),
  score_a integer not null default 0,
  score_b integer not null default 0,
  status text not null default 'active' check (status in ('active', 'ended')),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  check (stream_a_id <> stream_b_id)
);

alter table public.pk_battles enable row level security;

create policy "PK battles are publicly viewable"
  on public.pk_battles for select using (true);
create policy "Involved hosts and staff manage a PK battle"
  on public.pk_battles for update
  using (
    public.is_admin_or_above()
    or exists (
      select 1 from public.live_streams s
      where s.id in (stream_a_id, stream_b_id) and s.host_id = auth.uid()
    )
  );
create policy "Staff start PK battles"
  on public.pk_battles for insert with check (public.is_admin_or_above());
