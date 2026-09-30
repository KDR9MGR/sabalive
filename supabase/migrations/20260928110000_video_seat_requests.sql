-- Extends the "request a seat, host approves" flow (built for PK in
-- 20260927100000_pk_seat_requests.sql) to video live streams too, per Rey's
-- ask. Audio rooms are deliberately left untouched — self-serve claim_seat
-- still works there exactly as before; only video and PK now require the
-- host's approval. Reuses the same pk_seat_requests table/RPCs — the
-- approve/decline functions are already mode-agnostic, only the mode checks
-- in request_pk_seat and claim_seat need widening.

create or replace function public.request_pk_seat(p_stream_id uuid)
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
  if v_mode not in ('pk', 'video') then raise exception 'This stream does not use seat requests'; end if;
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
  if v_mode in ('pk', 'video') then
    raise exception 'This stream needs the host''s approval — request a seat instead';
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
