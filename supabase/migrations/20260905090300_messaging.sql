-- Direct messages. A conversation always has exactly the participants added
-- to it; a DM started by someone you don't follow lands as a pending
-- participant row for you — that's the "Message Requests" tab in the app.

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  is_group boolean not null default false,
  name text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);

create table public.conversation_participants (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'member' check (role in ('member', 'admin')),
  status text not null default 'accepted' check (status in ('pending', 'accepted', 'declined')),
  joined_at timestamptz not null default now(),
  last_read_at timestamptz,
  primary key (conversation_id, profile_id)
);

create table public.dm_messages (
  id bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null references public.profiles (id),
  body text,
  kind text not null default 'text' check (kind in ('text', 'gift', 'sticker')),
  gift_id uuid references public.gifts (id),
  created_at timestamptz not null default now()
);

create index dm_messages_conversation_idx on public.dm_messages (conversation_id, created_at desc);

alter table public.conversations enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.dm_messages enable row level security;

create function public.is_conversation_participant(p_conversation_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.conversation_participants
    where conversation_id = p_conversation_id and profile_id = auth.uid()
  );
$$;

create policy "Participants see their conversations"
  on public.conversations for select using (public.is_conversation_participant(id));
create policy "Signed-in users start conversations"
  on public.conversations for insert with check (created_by = auth.uid());

create policy "Participants see the participant list"
  on public.conversation_participants for select using (public.is_conversation_participant(conversation_id));
create policy "Conversation creator adds initial participants"
  on public.conversation_participants for insert
  with check (
    profile_id = auth.uid()
    or exists (select 1 from public.conversations c where c.id = conversation_id and c.created_by = auth.uid())
  );
create policy "Participants accept/decline/mark read for themselves"
  on public.conversation_participants for update using (profile_id = auth.uid());

create policy "Participants read conversation messages"
  on public.dm_messages for select using (public.is_conversation_participant(conversation_id));
create policy "Accepted participants send messages"
  on public.dm_messages for insert
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.conversation_participants cp
      where cp.conversation_id = dm_messages.conversation_id
        and cp.profile_id = auth.uid() and cp.status = 'accepted'
    )
  );
