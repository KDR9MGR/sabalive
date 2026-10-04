-- Support chat: each user has one running conversation with the support team. The
-- user writes from Settings -> Support in the app; Master and Super Admin read and
-- reply from the panel (Support), assign, and close. Users only ever see "Support",
-- never which admin replied.
create table public.support_threads (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  status text not null default 'open' check (status in ('open', 'closed')),
  assigned_to uuid references public.profiles (id) on delete set null,
  last_message_at timestamptz not null default now(),
  last_message text not null default '',
  -- unread counters so each side can show a badge without counting rows
  user_unread integer not null default 0,
  staff_unread integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.support_messages (
  id bigint generated always as identity primary key,
  thread_id uuid not null references public.support_threads (user_id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  from_staff boolean not null default false,
  body text not null check (length(trim(body)) > 0 and length(body) <= 2000),
  created_at timestamptz not null default now()
);
create index support_messages_thread_idx on public.support_messages (thread_id, id);
create index support_threads_inbox_idx on public.support_threads (status, last_message_at desc);

alter table public.support_threads enable row level security;
alter table public.support_messages enable row level security;

create policy "Users and support staff see the thread"
  on public.support_threads for select
  using (user_id = auth.uid() or public.staff_cap_on('manage_support'));
create policy "Users and support staff see the messages"
  on public.support_messages for select
  using (thread_id = auth.uid() or public.staff_cap_on('manage_support'));
-- no insert/update policies: everything goes through the RPCs below

alter publication supabase_realtime add table public.support_threads;
alter publication supabase_realtime add table public.support_messages;

-- a ghost can't write (it must stay unnoticeable)
create trigger support_messages_ghost_block
  before insert on public.support_messages
  for each row execute function public.assert_not_ghost();

-- Keeps the thread's preview, unread counters and open/closed state in step with
-- every message (so a customer writing to a closed thread reopens it).
create or replace function public.support_message_after_insert()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update public.support_threads set
    last_message_at = new.created_at,
    last_message = left(new.body, 140),
    user_unread = user_unread + case when new.from_staff then 1 else 0 end,
    staff_unread = staff_unread + case when new.from_staff then 0 else 1 end,
    status = case when new.from_staff then status else 'open' end
  where user_id = new.thread_id;
  return null;
end;
$$;
create trigger support_messages_after_insert
  after insert on public.support_messages
  for each row execute function public.support_message_after_insert();

-- The user writes to support.
create or replace function public.support_send(p_body text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_body text := trim(coalesce(p_body, ''));
begin
  if v_me is null then raise exception 'Sign in first'; end if;
  if v_body = '' then raise exception 'Write a message first'; end if;
  insert into public.support_threads (user_id) values (v_me) on conflict (user_id) do nothing;
  insert into public.support_messages (thread_id, sender_id, from_staff, body)
  values (v_me, v_me, false, v_body);
end;
$$;
revoke execute on function public.support_send(text) from public, anon;
grant execute on function public.support_send(text) to authenticated;

-- Support staff (Master / Super Admin) reply.
create or replace function public.support_reply(p_user uuid, p_body text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_body text := trim(coalesce(p_body, ''));
begin
  if not public.staff_cap_on('manage_support') then
    raise exception 'Only a Master or Super Admin can reply to support';
  end if;
  if v_body = '' then raise exception 'Write a message first'; end if;
  if not exists (select 1 from public.support_threads where user_id = p_user) then
    raise exception 'That conversation does not exist';
  end if;
  insert into public.support_messages (thread_id, sender_id, from_staff, body)
  values (p_user, auth.uid(), true, v_body);
  -- the first reply picks the conversation up if nobody has it
  update public.support_threads set assigned_to = coalesce(assigned_to, auth.uid()) where user_id = p_user;
end;
$$;
revoke execute on function public.support_reply(uuid, text) from public, anon;
grant execute on function public.support_reply(uuid, text) to authenticated;

-- The user opened the chat: their unread badge clears.
create or replace function public.support_mark_read()
returns void
language sql security definer set search_path = public
as $$
  update public.support_threads set user_unread = 0 where user_id = auth.uid() and user_unread <> 0;
$$;
revoke execute on function public.support_mark_read() from public, anon;
grant execute on function public.support_mark_read() to authenticated;

-- Staff opened a conversation: its staff badge clears.
create or replace function public.support_staff_mark_read(p_user uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.staff_cap_on('manage_support') then raise exception 'Not allowed'; end if;
  update public.support_threads set staff_unread = 0 where user_id = p_user and staff_unread <> 0;
end;
$$;
revoke execute on function public.support_staff_mark_read(uuid) from public, anon;
grant execute on function public.support_staff_mark_read(uuid) to authenticated;

-- Close / reopen, and assign (null = unassign) from the panel.
create or replace function public.support_set_thread(p_user uuid, p_status text, p_assignee uuid default null, p_assign boolean default false)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.staff_cap_on('manage_support') then raise exception 'Not allowed'; end if;
  if p_status is not null and p_status not in ('open', 'closed') then raise exception 'Status must be open or closed'; end if;
  if p_assign and p_assignee is not null and not exists (
    select 1 from public.staff_roles where user_id = p_assignee and role in ('admin', 'super_admin')
  ) then
    raise exception 'Only a Master or Super Admin can own a support conversation';
  end if;
  update public.support_threads set
    status = coalesce(p_status, status),
    assigned_to = case when p_assign then p_assignee else assigned_to end
  where user_id = p_user;
  if not found then raise exception 'That conversation does not exist'; end if;
end;
$$;
revoke execute on function public.support_set_thread(uuid, text, uuid, boolean) from public, anon;
grant execute on function public.support_set_thread(uuid, text, uuid, boolean) to authenticated;
