-- Real "request to join a PK seat, host approves" flow. Reuses the existing
-- live_stream_seats table/RLS/realtime (same one audio/video rooms already
-- use) for the actual occupancy once approved — a PK seat is not a
-- different kind of thing, just a guest seat on a stream, same as any
-- other — but PK seats are host-approval-gated, not self-serve like audio/
-- video, so claim_seat is extended to reject a direct self-serve claim on
-- a PK-mode stream and point the caller at this request flow instead.

create table public.pk_seat_requests (
  id uuid primary key default gen_random_uuid(),
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  requester_id uuid not null references public.profiles (id),
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'cancelled')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create unique index pk_seat_requests_one_pending
  on public.pk_seat_requests (live_stream_id, requester_id)
  where status = 'pending';

alter table public.pk_seat_requests enable row level security;

create policy "Requesters and the host see relevant requests"
  on public.pk_seat_requests for select
  using (
    requester_id = auth.uid()
    or exists (select 1 from public.live_streams s where s.id = live_stream_id and s.host_id = auth.uid())
  );

-- ---------------------------------------------------------------- request_pk_seat
create function public.request_pk_seat(p_stream_id uuid)
returns public.pk_seat_requests
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_mode text;
  v_status text;
  v_row public.pk_seat_requests;
begin
  if v_me is null then raise exception 'Must be signed in to request a seat'; end if;
  select mode, status into v_mode, v_status from public.live_streams where id = p_stream_id;
  if v_mode is null then raise exception 'Stream not found'; end if;
  if v_mode <> 'pk' then raise exception 'This is only for PK battle seats'; end if;
  if v_status <> 'live' then raise exception 'This stream is not live'; end if;
  if exists (select 1 from public.live_stream_seats where live_stream_id = p_stream_id and occupant_id = v_me) then
    raise exception 'You are already on a seat here';
  end if;

  insert into public.pk_seat_requests (live_stream_id, requester_id)
  values (p_stream_id, v_me)
  on conflict (live_stream_id, requester_id) where status = 'pending' do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.pk_seat_requests
    where live_stream_id = p_stream_id and requester_id = v_me and status = 'pending';
  end if;

  return v_row;
end;
$$;
revoke execute on function public.request_pk_seat(uuid) from public;
grant execute on function public.request_pk_seat(uuid) to authenticated;

-- ---------------------------------------------------------- approve_pk_seat_request
create function public.approve_pk_seat_request(p_request_id uuid, p_seat integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_req public.pk_seat_requests%rowtype;
begin
  select * into v_req from public.pk_seat_requests where id = p_request_id;
  if not found then raise exception 'Request not found'; end if;
  if v_req.status <> 'pending' then raise exception 'This request has already been handled'; end if;
  if not exists (
    select 1 from public.live_streams where id = v_req.live_stream_id and host_id = auth.uid()
  ) then
    raise exception 'Only the host can do this';
  end if;
  if exists (
    select 1 from public.live_stream_seats
    where live_stream_id = v_req.live_stream_id and seat_number = p_seat
  ) then
    raise exception 'That seat is already taken';
  end if;

  insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at)
  values (v_req.live_stream_id, p_seat, v_req.requester_id, now());

  update public.pk_seat_requests set status = 'approved', decided_at = now() where id = p_request_id;
end;
$$;
revoke execute on function public.approve_pk_seat_request(uuid, integer) from public;
grant execute on function public.approve_pk_seat_request(uuid, integer) to authenticated;

-- ---------------------------------------------------------- decline_pk_seat_request
create function public.decline_pk_seat_request(p_request_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.pk_seat_requests r
    join public.live_streams s on s.id = r.live_stream_id
    where r.id = p_request_id and s.host_id = auth.uid()
  ) then
    raise exception 'Only the host can do this';
  end if;
  update public.pk_seat_requests set status = 'declined', decided_at = now()
  where id = p_request_id and status = 'pending';
end;
$$;
revoke execute on function public.decline_pk_seat_request(uuid) from public;
grant execute on function public.decline_pk_seat_request(uuid) to authenticated;

-- ------------------------------------------------------- claim_seat rejects PK
create or replace function public.claim_seat(p_stream_id uuid, p_seat integer)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_status text;
  v_mode text;
  v_locked integer[];
begin
  if auth.uid() is null then raise exception 'Must be signed in to claim a seat'; end if;
  if exists (
    select 1 from public.live_stream_seat_bans
    where live_stream_id = p_stream_id and banned_id = auth.uid()
  ) then
    raise exception 'You have been removed from this room''s seats by the host';
  end if;
  select status, mode, locked_seats into v_status, v_mode, v_locked
    from public.live_streams where id = p_stream_id;
  if v_status is null then raise exception 'Stream not found'; end if;
  if v_mode = 'pk' then
    raise exception 'PK Battle seats need the host''s approval — request a seat instead';
  end if;
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
