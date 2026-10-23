-- Down script for supabase/migrations/20261023120000_seat_security.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Cannot be undone by this script: the seat rows the one-time sweep deleted (out-of-range audio seats, a few at most, no value after the room
-- ends), and any agora_token_log rows (dropped with the table: copy them first if they are needed).
-- WARNING: putting the client INSERT rights back re-opens the hole it closed (anyone could seat themselves anywhere and be given a speaking
-- token). Only do it if a shipped app turns out to need it.
begin;
set local lock_timeout = '5s';

-- the client INSERT rights and policies, as they were
grant insert on public.live_stream_seats to anon, authenticated;
drop policy if exists "Occupants claim their own seat" on public.live_stream_seats;
create policy "Occupants claim their own seat" on public.live_stream_seats for insert with check (occupant_id = auth.uid());
grant insert on public.live_stream_viewers to anon, authenticated;
drop policy if exists "Viewers log their own join" on public.live_stream_viewers;
create policy "Viewers log their own join" on public.live_stream_viewers for insert with check (viewer_id = auth.uid());

-- claim_seat and set_seat_count, as they were (no seat-range rule, no vacating on a lowered count)
create or replace function public.claim_seat(p_stream_id uuid, p_seat integer)
returns void
language plpgsql security definer set search_path = public
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

-- the token log
do $$ begin
  if exists (select 1 from cron.job where jobname = 'prune-agora-token-log') then perform cron.unschedule('prune-agora-token-log'); end if;
end $$;
drop table if exists public.agora_token_log;

commit;
