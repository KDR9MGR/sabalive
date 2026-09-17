-- Real seat occupancy for audio rooms (instant, self-serve claim — no host
-- approval). Mirrors live_stream_viewers: a small presence table +
-- SECURITY DEFINER RPCs restricted to authenticated + realtime publication
-- registration. Unlike the viewers table (a historical log), this is
-- current-state: one row per occupied seat, replaced on re-claim.

create table public.live_stream_seats (
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  seat_number integer not null check (seat_number between 1 and 12),
  occupant_id uuid not null references public.profiles (id) on delete cascade,
  claimed_at timestamptz not null default now(),
  primary key (live_stream_id, seat_number),
  unique (live_stream_id, occupant_id)
);

alter table public.live_stream_seats enable row level security;

create policy "Seat occupancy is publicly viewable"
  on public.live_stream_seats for select using (true);
create policy "Occupants claim their own seat"
  on public.live_stream_seats for insert with check (occupant_id = auth.uid());
create policy "Occupants and the host release a seat"
  on public.live_stream_seats for delete
  using (
    occupant_id = auth.uid()
    or public.is_admin_or_above()
    or exists (select 1 from public.live_streams s
               where s.id = live_stream_id and s.host_id = auth.uid())
  );

alter publication supabase_realtime add table public.live_stream_seats;

-- Seat locking must be persisted (not host-local-only, as it was before)
-- or claim_seat below can't enforce it server-side. One column, written
-- only through a host-scoped RPC.
alter table public.live_streams add column locked_seats integer[] not null default '{}';

create function public.set_seat_lock(p_stream_id uuid, p_seat integer, p_locked boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_locked then
    update public.live_streams
    set locked_seats = (select array_agg(distinct x) from unnest(locked_seats || p_seat) as x)
    where id = p_stream_id and host_id = auth.uid();
  else
    update public.live_streams set locked_seats = array_remove(locked_seats, p_seat)
    where id = p_stream_id and host_id = auth.uid();
  end if;
end;
$$;
revoke execute on function public.set_seat_lock(uuid, integer, boolean) from public;
grant execute on function public.set_seat_lock(uuid, integer, boolean) to authenticated;

create function public.claim_seat(p_stream_id uuid, p_seat integer)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_status text;
  v_locked integer[];
begin
  if auth.uid() is null then raise exception 'Must be signed in to claim a seat'; end if;
  select status, locked_seats into v_status, v_locked from public.live_streams where id = p_stream_id;
  if v_status is null then raise exception 'Stream not found'; end if;
  if v_status <> 'live' then raise exception 'This stream is not live'; end if;
  if p_seat = any(v_locked) then raise exception 'This seat is locked'; end if;
  if exists (select 1 from public.live_stream_seats
             where live_stream_id = p_stream_id and seat_number = p_seat) then
    raise exception 'This seat is already taken';
  end if;
  -- Re-claiming (moving seats) should be idempotent, not a conflict with
  -- the caller's own prior row.
  delete from public.live_stream_seats
  where live_stream_id = p_stream_id and occupant_id = auth.uid();
  insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id)
  values (p_stream_id, p_seat, auth.uid());
exception
  when unique_violation then raise exception 'Someone just took that seat';
end;
$$;

create function public.release_seat(p_stream_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.live_stream_seats
  where live_stream_id = p_stream_id and occupant_id = auth.uid();
end;
$$;
revoke execute on function public.claim_seat(uuid, integer) from public;
grant execute on function public.claim_seat(uuid, integer) to authenticated;
revoke execute on function public.release_seat(uuid) from public;
grant execute on function public.release_seat(uuid) to authenticated;
