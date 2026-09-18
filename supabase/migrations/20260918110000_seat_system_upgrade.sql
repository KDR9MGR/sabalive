-- Seat system overhaul: 5-per-row/max-25 layout (audio rooms), real synced
-- seat count (was host-local-only), self-mute state, and connection-loss
-- timeouts for viewers and seat holders — mirroring the existing
-- end_stale_live_streams heartbeat/cron pattern.

alter table public.live_stream_seats drop constraint live_stream_seats_seat_number_check;
alter table public.live_stream_seats add constraint live_stream_seats_seat_number_check
  check (seat_number between 1 and 25);

alter table public.live_streams add column seat_count integer not null default 5
  check (seat_count between 5 and 25);

alter table public.live_stream_seats add column is_muted boolean not null default false;

alter table public.live_stream_viewers add column last_heartbeat_at timestamptz not null default now();
alter table public.live_stream_seats add column last_heartbeat_at timestamptz not null default now();

-- ---------------------------------------------------------------- set_seat_count
create function public.set_seat_count(p_stream_id uuid, p_count integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_count < 5 or p_count > 25 or p_count % 5 <> 0 then
    raise exception 'Seat count must be a multiple of 5 between 5 and 25';
  end if;
  update public.live_streams set seat_count = p_count
  where id = p_stream_id and host_id = auth.uid();
end;
$$;
revoke execute on function public.set_seat_count(uuid, integer) from public;
grant execute on function public.set_seat_count(uuid, integer) to authenticated;

-- ---------------------------------------------------------------- set_seat_mute
create function public.set_seat_mute(p_stream_id uuid, p_muted boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_stream_seats set is_muted = p_muted
  where live_stream_id = p_stream_id and occupant_id = auth.uid();
  if not found then
    raise exception 'You are not seated in this room';
  end if;
end;
$$;
revoke execute on function public.set_seat_mute(uuid, boolean) from public;
grant execute on function public.set_seat_mute(uuid, boolean) to authenticated;

-- --------------------------------------------------------------- heartbeat_viewer
create function public.heartbeat_viewer(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_stream_viewers set last_heartbeat_at = now()
  where live_stream_id = p_stream_id and viewer_id = auth.uid() and left_at is null;
end;
$$;
revoke execute on function public.heartbeat_viewer(uuid) from public;
grant execute on function public.heartbeat_viewer(uuid) to authenticated;

-- ----------------------------------------------------------- claim_seat / release_seat
-- Redefined (same signatures) to also stamp last_heartbeat_at, so a
-- freshly-claimed seat isn't immediately eligible for the staleness sweep
-- before the claimant's first heartbeat lands.
create or replace function public.claim_seat(p_stream_id uuid, p_seat integer)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_status text;
  v_locked integer[];
begin
  if auth.uid() is null then raise exception 'Must be signed in to claim a seat'; end if;
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

create or replace function public.release_seat(p_stream_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  delete from public.live_stream_seats
  where live_stream_id = p_stream_id and occupant_id = auth.uid();
end;
$$;

-- -------------------------------------------------------------- finalize_stale_presence
create function public.finalize_stale_presence()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.live_stream_seats where last_heartbeat_at < now() - interval '90 seconds';
  update public.live_stream_viewers set left_at = now()
  where left_at is null and last_heartbeat_at < now() - interval '90 seconds';
end;
$$;

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'finalize-stale-presence') then
    perform cron.schedule(
      'finalize-stale-presence',
      '* * * * *',
      $sql$select public.finalize_stale_presence()$sql$
    );
  end if;
end;
$outer$;
