-- Host moderation for seat occupants (kick / mute / ban) on both video and
-- audio live streams, plus making the "who's watching" list public (Rey
-- wants any viewer to be able to see who else is watching, not just the
-- host) instead of host/staff/self-only.

-- ---------------------------------------------------------------- bans
create table public.live_stream_seat_bans (
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  banned_id uuid not null references public.profiles (id) on delete cascade,
  banned_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  primary key (live_stream_id, banned_id)
);

alter table public.live_stream_seat_bans enable row level security;

create policy "Hosts and staff see a stream's seat bans"
  on public.live_stream_seat_bans for select
  using (
    public.is_admin_or_above()
    or exists (select 1 from public.live_streams s where s.id = live_stream_id and s.host_id = auth.uid())
  );

-- --------------------------------------------------------- kick_seat_occupant
create function public.kick_seat_occupant(p_stream_id uuid, p_seat integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()
  ) then
    raise exception 'Only the host can do this';
  end if;
  delete from public.live_stream_seats
  where live_stream_id = p_stream_id and seat_number = p_seat;
end;
$$;
revoke execute on function public.kick_seat_occupant(uuid, integer) from public;
grant execute on function public.kick_seat_occupant(uuid, integer) to authenticated;

-- ---------------------------------------------------------- ban_seat_occupant
create function public.ban_seat_occupant(p_stream_id uuid, p_seat integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_occupant uuid;
begin
  if not exists (
    select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()
  ) then
    raise exception 'Only the host can do this';
  end if;
  select occupant_id into v_occupant from public.live_stream_seats
  where live_stream_id = p_stream_id and seat_number = p_seat;
  if v_occupant is null then
    raise exception 'No one is on that seat';
  end if;
  delete from public.live_stream_seats
  where live_stream_id = p_stream_id and seat_number = p_seat;
  insert into public.live_stream_seat_bans (live_stream_id, banned_id, banned_by)
  values (p_stream_id, v_occupant, auth.uid())
  on conflict (live_stream_id, banned_id) do nothing;
end;
$$;
revoke execute on function public.ban_seat_occupant(uuid, integer) from public;
grant execute on function public.ban_seat_occupant(uuid, integer) to authenticated;

-- ------------------------------------------------------------- host_set_seat_mute
-- Distinct from the existing self-serve set_seat_mute (that one only lets an
-- occupant mute themselves) — this lets the host mute/unmute ANY seat.
create function public.host_set_seat_mute(p_stream_id uuid, p_seat integer, p_muted boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()
  ) then
    raise exception 'Only the host can do this';
  end if;
  update public.live_stream_seats set is_muted = p_muted
  where live_stream_id = p_stream_id and seat_number = p_seat;
  if not found then
    raise exception 'No one is on that seat';
  end if;
end;
$$;
revoke execute on function public.host_set_seat_mute(uuid, integer, boolean) from public;
grant execute on function public.host_set_seat_mute(uuid, integer, boolean) to authenticated;

-- ----------------------------------------------------- claim_seat rejects bans
create or replace function public.claim_seat(p_stream_id uuid, p_seat integer)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_status text;
  v_locked integer[];
begin
  if auth.uid() is null then raise exception 'Must be signed in to claim a seat'; end if;
  if exists (
    select 1 from public.live_stream_seat_bans
    where live_stream_id = p_stream_id and banned_id = auth.uid()
  ) then
    raise exception 'You have been removed from this room''s seats by the host';
  end if;
  select status, locked_seats into v_status, v_locked from public.live_streams where id = p_stream_id;
  if v_status is null then raise exception 'Stream not found'; end if;
  if v_status <> 'live' then raise exception 'This stream is not live'; end if;
  if p_seat = any(v_locked) then raise exception 'This seat is locked'; end if;
  if exists (
    select 1 from public.live_stream_seats
    where live_stream_id = p_stream_id and seat_number = p_seat
  ) then
    raise exception 'This seat is already taken';
  end if;
  delete from public.live_stream_seats
  where live_stream_id = p_stream_id and occupant_id = auth.uid();
  insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at)
  values (p_stream_id, p_seat, auth.uid(), now());
exception
  when unique_violation then raise exception 'Someone just took that seat';
end;
$$;

-- ------------------------------------------------------- public viewer list
create policy "Anyone can see who's watching a stream"
  on public.live_stream_viewers for select
  using (true);
