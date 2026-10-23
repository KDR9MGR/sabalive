-- Seat security (incident 2026-10-23 ~15:55 IST, a Customer Service audio live): someone spoke without sitting on a visible seat and left no
-- "joined" line. How it was possible, all verified against production:
--
--   1. live_stream_seats had an INSERT policy "Occupants claim their own seat" (occupant_id = auth.uid()) and the table grant to
--      `authenticated`: ANY signed-in client could write its own seat row straight into the table, in any live (audio, video, PK, even an
--      ended one), skipping claim_seat's rules (seat locked, host approval for video / PK, seat range) and without a "joined" line. The agora-token
--      function then trusted the row and minted a speaking (publisher) token. No shipped app build does this: every build since the first
--      Play release only SELECTs the table and writes through claim_seat / release_seat / heartbeat_seat / the host functions, which are all
--      SECURITY DEFINER (so they keep working when the client's INSERT right is taken away).
--   2. Nothing checked that a seat number exists. claim_seat took ANY number and set_seat_count never removed seats beyond a lowered count, so
--      a seat 6 of a 4-seat room is invisible to the host (cannot be seen or kicked) yet still held the right to speak. One such seat was found
--      live in production while investigating (room f34b4f2e..., seat 6 of 4).
--   3. live_stream_viewers has the same kind of INSERT policy ("Viewers log their own join"): a client could be "in the room" with no viewer
--      line and no "joined" message. Only join_live_stream (SECURITY DEFINER) writes that row for the app.
--   4. No record of who was given a speaking token (Agora shows only anonymous uids), so a speaker could not be named afterwards.
--
-- What this migration does (all additive for the apps in the field; rollback: supabase/rollbacks/20261023120000_down.sql):
--   * seats and viewers can be written ONLY by the existing SECURITY DEFINER functions (client INSERT policy dropped and right revoked);
--   * claim_seat refuses a seat number outside 1..seat_count (body otherwise identical to the live one);
--   * set_seat_count vacates the seats beyond a lowered count in an audio room (the occupants' apps already react to a seat row disappearing);
--   * a one-time sweep of audio-room seats that are outside their room's range right now;
--   * agora_token_log: who was granted / refused a speaking token (written by the agora-token function with the service role, Super Admin reads),
--     pruned after 30 days.
set local lock_timeout = '5s';

-- 1 + 3. only the seat / join functions write these tables
drop policy if exists "Occupants claim their own seat" on public.live_stream_seats;
revoke insert on public.live_stream_seats from anon, authenticated;
drop policy if exists "Viewers log their own join" on public.live_stream_viewers;
revoke insert on public.live_stream_viewers from anon, authenticated;

-- 2a. claim_seat: the seat must exist (everything else is the live body, unchanged)
create or replace function public.claim_seat(p_stream_id uuid, p_seat integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_status text;
  v_mode text;
  v_locked integer[];
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Must be signed in to claim a seat'; end if;
  if exists (
    select 1 from public.live_stream_seat_bans
    where live_stream_id = p_stream_id and banned_id = auth.uid()
  ) then
    raise exception 'You have been removed from this room''s seats by the host';
  end if;
  select status, mode, locked_seats, seat_count into v_status, v_mode, v_locked, v_count
    from public.live_streams where id = p_stream_id;
  if v_status is null then raise exception 'Stream not found'; end if;
  if v_mode in ('pk', 'video') then
    raise exception 'This stream needs the host''s approval — request a seat instead';
  end if;
  if v_status <> 'live' then raise exception 'This stream is not live'; end if;
  if p_seat is null or p_seat < 1 or p_seat > v_count then raise exception 'That seat does not exist'; end if;
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

-- 2b. set_seat_count: lowering the count vacates the seats that no longer exist (audio rooms only; video / PK keep their own numbering)
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
  if found then
    delete from public.live_stream_seats k
     using public.live_streams s
     where k.live_stream_id = p_stream_id and s.id = k.live_stream_id
       and s.mode = 'audio' and k.seat_number > p_count;
  end if;
end;
$$;

-- 2c. one-time sweep: audio-room seats outside their room's range (invisible to the host, but still entitled to speak)
delete from public.live_stream_seats k
 using public.live_streams s
 where s.id = k.live_stream_id and s.mode = 'audio'
   and (k.seat_number < 1 or k.seat_number > s.seat_count);

-- 4. who was given a speaking token
create table if not exists public.agora_token_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null,            -- no foreign key: the trail must outlive an account
  channel text not null,            -- the live's id (or a call / battle channel name)
  outcome text not null check (outcome in ('granted', 'refused')),
  reason text,
  device_id text,
  ip text
);
create index if not exists agora_token_log_created_idx on public.agora_token_log (created_at desc);
create index if not exists agora_token_log_user_idx on public.agora_token_log (user_id, created_at desc);
create index if not exists agora_token_log_channel_idx on public.agora_token_log (channel, created_at desc);
alter table public.agora_token_log enable row level security;
revoke all on public.agora_token_log from anon, authenticated;
grant select on public.agora_token_log to authenticated;
drop policy if exists "Super Admin reads the token log" on public.agora_token_log;
create policy "Super Admin reads the token log" on public.agora_token_log for select using (public.is_super_admin());

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'prune-agora-token-log') then
    perform cron.schedule('prune-agora-token-log', '17 3 * * *',
      $sql$delete from public.agora_token_log where created_at < now() - interval '30 days'$sql$);
  end if;
end;
$outer$;
