-- Live moderation: room admins, kick, text ban, and seat counts in steps of 4.
--
-- * Room admins: a host picks up to 5 people as admins. They are admins in every live that host runs, and have the
--   host's moderation tools (kick, ban from the live, ban text, mute / lock / remove seats) but cannot end the live,
--   add admins or touch gifts. An admin cannot act on the host or on another admin.
-- * Kick: removes someone from the live right now; they may come back in (block_viewer, "Ban", is the one that keeps
--   them out for the rest of that live).
-- * Ban text (live_chat_mutes): the person stays in the room but cannot chat until the live ends or a moderator lifts it.
-- * Seats: 4 per row, 4 to 16 seats in steps of 4 in the new app. The database check widened from 5..25 to 4..25 so the
--   new counts fit; installed apps keep sending multiples of 5, which are still accepted.
--
-- Additive for installed apps: new tables and functions; the existing moderation functions keep their names and
-- arguments and only ALSO accept a room admin; one new BEFORE INSERT trigger on live_chat_messages that refuses a
-- muted person's text and stickers (system, gift and join rows are never blocked).

-- ---------------------------------------------------------------- seat counts
alter table public.live_streams drop constraint if exists live_streams_seat_count_check;
alter table public.live_streams add constraint live_streams_seat_count_check check (seat_count between 4 and 25);

create or replace function public.set_seat_count(p_stream_id uuid, p_count integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_count < 4 or p_count > 25 then
    raise exception 'Seat count must be between 4 and 25';
  end if;
  update public.live_streams set seat_count = p_count
  where id = p_stream_id and host_id = auth.uid();
end;
$$;

-- ---------------------------------------------------------------- room admins
create table if not exists public.live_room_admins (
  host_id uuid not null references public.profiles (id) on delete cascade,
  admin_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (host_id, admin_id),
  check (host_id <> admin_id)
);
alter table public.live_room_admins enable row level security;
-- who the admins are is visible to everyone in a room (the app marks them); changes only through set_room_admin
drop policy if exists "Room admins are visible" on public.live_room_admins;
create policy "Room admins are visible" on public.live_room_admins for select using (true);
revoke insert, update, delete on public.live_room_admins from authenticated, anon;

create or replace function public.set_room_admin(p_admin uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  if p_admin = v_me then
    raise exception 'You are already the host';
  end if;
  if p_on then
    if not exists (select 1 from public.profiles where id = p_admin) or public.is_ghost(p_admin) then
      raise exception 'That person cannot be an admin';
    end if;
    if (select count(*) from public.live_room_admins where host_id = v_me) >= 5
       and not exists (select 1 from public.live_room_admins where host_id = v_me and admin_id = p_admin) then
      raise exception 'You can have up to 5 room admins';
    end if;
    insert into public.live_room_admins (host_id, admin_id) values (v_me, p_admin) on conflict do nothing;
  else
    delete from public.live_room_admins where host_id = v_me and admin_id = p_admin;
  end if;
end;
$$;
revoke execute on function public.set_room_admin(uuid, boolean) from public, anon;
grant execute on function public.set_room_admin(uuid, boolean) to authenticated;

-- the host of a live, or one of that host's room admins
create or replace function public.is_room_moderator(p_stream_id uuid, p_user uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select p_user is not null and exists (
    select 1 from public.live_streams s
     where s.id = p_stream_id
       and (s.host_id = p_user
            or exists (select 1 from public.live_room_admins a where a.host_id = s.host_id and a.admin_id = p_user))
  );
$$;
revoke execute on function public.is_room_moderator(uuid, uuid) from public, anon;
grant execute on function public.is_room_moderator(uuid, uuid) to authenticated;

-- the shared guard: the caller moderates this live and the target is someone they may act on
create or replace function public._assert_can_moderate(p_stream_id uuid, p_target uuid)
returns void
language plpgsql stable security definer set search_path = public
as $$
declare
  v_host uuid;
begin
  select host_id into v_host from public.live_streams where id = p_stream_id;
  if v_host is null then
    raise exception 'This live no longer exists';
  end if;
  if not public.is_room_moderator(p_stream_id, auth.uid()) then
    raise exception 'Only the host or a room admin can do this';
  end if;
  if p_target = auth.uid() then
    raise exception 'You can''t do that to yourself';
  end if;
  if p_target = v_host then
    raise exception 'You can''t do that to the host';
  end if;
  if auth.uid() <> v_host and exists (select 1 from public.live_room_admins where host_id = v_host and admin_id = p_target) then
    raise exception 'Only the host can do that to an admin';
  end if;
end;
$$;
revoke execute on function public._assert_can_moderate(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- kick (can come back)
create table if not exists public.live_stream_kicks (
  id bigint generated always as identity primary key,
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kicked_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists live_stream_kicks_user_idx on public.live_stream_kicks (user_id, created_at desc);
alter table public.live_stream_kicks enable row level security;
-- the kicked person's phone listens for its own row, which is how it knows to leave
drop policy if exists "A kick is visible to the person kicked" on public.live_stream_kicks;
create policy "A kick is visible to the person kicked" on public.live_stream_kicks for select using (user_id = auth.uid());
revoke insert, update, delete on public.live_stream_kicks from authenticated, anon;

create or replace function public.kick_viewer(p_stream_id uuid, p_user_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_can_moderate(p_stream_id, p_user_id);
  update public.live_stream_viewers set left_at = now()
   where live_stream_id = p_stream_id and viewer_id = p_user_id and left_at is null;
  delete from public.live_stream_seats where live_stream_id = p_stream_id and occupant_id = p_user_id;
  insert into public.live_stream_kicks (live_stream_id, user_id, kicked_by) values (p_stream_id, p_user_id, auth.uid());
  delete from public.live_stream_kicks where created_at < now() - interval '1 day';
end;
$$;
revoke execute on function public.kick_viewer(uuid, uuid) from public, anon;
grant execute on function public.kick_viewer(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------- ban text
create table if not exists public.live_chat_mutes (
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  muted_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (live_stream_id, user_id)
);
alter table public.live_chat_mutes enable row level security;
drop policy if exists "A text ban is visible to the person and to moderators" on public.live_chat_mutes;
create policy "A text ban is visible to the person and to moderators" on public.live_chat_mutes for select
  using (user_id = auth.uid() or public.is_room_moderator(live_stream_id, auth.uid()));
revoke insert, update, delete on public.live_chat_mutes from authenticated, anon;

create or replace function public.mute_chat(p_stream_id uuid, p_user_id uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_can_moderate(p_stream_id, p_user_id);
  if p_on then
    insert into public.live_chat_mutes (live_stream_id, user_id, muted_by) values (p_stream_id, p_user_id, auth.uid())
    on conflict (live_stream_id, user_id) do nothing;
  else
    delete from public.live_chat_mutes where live_stream_id = p_stream_id and user_id = p_user_id;
  end if;
end;
$$;
revoke execute on function public.mute_chat(uuid, uuid, boolean) from public, anon;
grant execute on function public.mute_chat(uuid, uuid, boolean) to authenticated;

create or replace function public.assert_chat_not_muted()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.kind in ('text', 'sticker')
     and exists (select 1 from public.live_chat_mutes m where m.live_stream_id = new.live_stream_id and m.user_id = new.sender_id) then
    raise exception 'The host has turned your chat off for this live' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke execute on function public.assert_chat_not_muted() from public, anon, authenticated;
drop trigger if exists live_chat_mute_check on public.live_chat_messages;
create trigger live_chat_mute_check before insert on public.live_chat_messages
  for each row execute function public.assert_chat_not_muted();

-- ---------------------------------------------------------------- the existing tools also accept a room admin
create or replace function public.block_viewer(p_stream_id uuid, p_user_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_can_moderate(p_stream_id, p_user_id);

  insert into public.live_stream_viewer_bans (live_stream_id, user_id, banned_by)
  values (p_stream_id, p_user_id, auth.uid())
  on conflict (live_stream_id, user_id) do nothing;

  update public.live_stream_viewers set left_at = now()
   where live_stream_id = p_stream_id and viewer_id = p_user_id and left_at is null;
  delete from public.live_stream_seats
   where live_stream_id = p_stream_id and occupant_id = p_user_id;
end;
$$;

create or replace function public.kick_seat_occupant(p_stream_id uuid, p_seat integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_occupant uuid;
begin
  select occupant_id into v_occupant from public.live_stream_seats
   where live_stream_id = p_stream_id and seat_number = p_seat;
  if v_occupant is not null then
    perform public._assert_can_moderate(p_stream_id, v_occupant);
  elsif not public.is_room_moderator(p_stream_id, auth.uid()) then
    raise exception 'Only the host or a room admin can do this';
  end if;
  delete from public.live_stream_seats where live_stream_id = p_stream_id and seat_number = p_seat;
end;
$$;

create or replace function public.ban_seat_occupant(p_stream_id uuid, p_seat integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_occupant uuid;
begin
  select occupant_id into v_occupant from public.live_stream_seats
   where live_stream_id = p_stream_id and seat_number = p_seat;
  if v_occupant is null then
    raise exception 'No one is on that seat';
  end if;
  perform public._assert_can_moderate(p_stream_id, v_occupant);
  delete from public.live_stream_seats where live_stream_id = p_stream_id and seat_number = p_seat;
  insert into public.live_stream_seat_bans (live_stream_id, banned_id, banned_by)
  values (p_stream_id, v_occupant, auth.uid())
  on conflict (live_stream_id, banned_id) do nothing;
end;
$$;

create or replace function public.host_set_seat_mute(p_stream_id uuid, p_seat integer, p_muted boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_occupant uuid;
begin
  select occupant_id into v_occupant from public.live_stream_seats
   where live_stream_id = p_stream_id and seat_number = p_seat;
  if v_occupant is null then
    raise exception 'No one is on that seat';
  end if;
  -- the host may mute anyone but themself (their own mic is theirs); an admin may mute neither host nor other admins
  if v_occupant = (select host_id from public.live_streams where id = p_stream_id) and auth.uid() = v_occupant then
    update public.live_stream_seats set is_muted = p_muted where live_stream_id = p_stream_id and seat_number = p_seat;
    return;
  end if;
  perform public._assert_can_moderate(p_stream_id, v_occupant);
  update public.live_stream_seats set is_muted = p_muted
  where live_stream_id = p_stream_id and seat_number = p_seat;
end;
$$;

create or replace function public.set_seat_lock(p_stream_id uuid, p_seat integer, p_locked boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_room_moderator(p_stream_id, auth.uid()) then
    raise exception 'Only the host or a room admin can do this';
  end if;
  if p_locked then
    update public.live_streams
    set locked_seats = (select array_agg(distinct x) from unnest(locked_seats || p_seat) as x)
    where id = p_stream_id;
  else
    update public.live_streams set locked_seats = array_remove(locked_seats, p_seat)
    where id = p_stream_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------- Realtime: the apps react to these at once
do $$
declare
  t text;
begin
  foreach t in array array['live_room_admins', 'live_stream_kicks', 'live_chat_mutes'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end
$$;

-- signed-out callers never need these (and would only be refused inside): close the explicit grant Supabase adds
revoke execute on function public.block_viewer(uuid, uuid) from anon;
revoke execute on function public.kick_seat_occupant(uuid, integer) from anon;
revoke execute on function public.ban_seat_occupant(uuid, integer) from anon;
revoke execute on function public.host_set_seat_mute(uuid, integer, boolean) from anon;
revoke execute on function public.set_seat_lock(uuid, integer, boolean) from anon;
revoke execute on function public.set_seat_count(uuid, integer) from anon;
