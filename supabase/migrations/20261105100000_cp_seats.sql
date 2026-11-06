-- CP (couple) seats in an AUDIO room (owner, 2026-11-05): two extra seats shown above the room's seat grid with a couple banner. The HOST adds / removes them
-- and is seated on the left one automatically; who else may sit on the other one is not decided yet (see cp_seat_refusal below: ONE place to put the rule).
--
-- How, and why it is additive (old apps stay in the field for months, root CLAUDE.md "Only add while old apps are live"):
--   * the two CP seats are the seat numbers 24 (left, the host's) and 25 (right). live_stream_seats already accepts 1..25 (its check constraint) and the app's grid never goes
--     above 16, so no seat table or constraint changes. An old app simply never draws seats 24 / 25 (and can still hear the people on them).
--   * live_streams.cp_seats boolean not null default false: a new column with a constant default, nothing reads it but the new code.
--   * NEW functions only (new names): claim_cp_seat, set_cp_seats, set_seat_count_v2, cp_seat_refusal. claim_seat / set_seat_count / release_seat are NOT changed:
--     claim_seat still refuses a seat above seat_count, which is exactly why CP seats need their own function.
--   * set_seat_count (the old function) deletes seats above a lowered count; in a room with CP seats that would delete the couple. The new app calls
--     set_seat_count_v2 when CP seats are on (it skips seats 24 / 25 of a room that has them) and the old function otherwise.
-- The agora-token function (and livekit-token) must also learn that seats 24 / 25 of a cp_seats room give the microphone: deploy this migration FIRST, then the functions.
-- Rollback: supabase/rollbacks/20261105100000_down.sql.
set local lock_timeout = '5s';

alter table public.live_streams add column if not exists cp_seats boolean not null default false;

-- The rule for who may sit on a CP seat. NOT DECIDED YET (owner: "conditions who can sit on it I will let you know later"): today anybody who may sit on
-- an ordinary seat may sit on the right one, and only the host on the left. Returns the reason for a refusal, or null when allowed. When the rule is known it
-- is changed here, in this one function, and nowhere else.
create or replace function public.cp_seat_refusal(p_stream_id uuid, p_user uuid, p_seat integer)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare
  v_host uuid;
begin
  select host_id into v_host from public.live_streams where id = p_stream_id;
  if p_seat = 24 and p_user is distinct from v_host then
    return 'The left couple seat is the host''s';
  end if;
  return null;
end;
$$;
revoke execute on function public.cp_seat_refusal(uuid, uuid, integer) from public, anon, authenticated;

-- Sit on a couple seat. Same rules as claim_seat (signed in, not seat-banned, the live is on, not locked, not taken, the caller's other seat is given up), plus:
-- an audio room, CP seats switched on, seat 24 or 25, and cp_seat_refusal says yes.
create or replace function public.claim_cp_seat(p_stream_id uuid, p_seat integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_status text;
  v_mode text;
  v_locked integer[];
  v_cp boolean;
  v_why text;
begin
  if auth.uid() is null then raise exception 'Must be signed in to claim a seat'; end if;
  if exists (
    select 1 from public.live_stream_seat_bans
    where live_stream_id = p_stream_id and banned_id = auth.uid()
  ) then
    raise exception 'You have been removed from this room''s seats by the host';
  end if;
  select status, mode, locked_seats, cp_seats into v_status, v_mode, v_locked, v_cp
    from public.live_streams where id = p_stream_id;
  if v_status is null then raise exception 'Stream not found'; end if;
  if v_status <> 'live' then raise exception 'This stream is not live'; end if;
  if v_mode <> 'audio' or not coalesce(v_cp, false) then raise exception 'This room has no couple seats'; end if;
  if p_seat is null or p_seat not in (24, 25) then raise exception 'That seat does not exist'; end if;
  if p_seat = any(v_locked) then raise exception 'This seat is locked'; end if;
  v_why := public.cp_seat_refusal(p_stream_id, auth.uid(), p_seat);
  if v_why is not null then raise exception '%', v_why; end if;
  -- taken by SOMEONE ELSE (the host coming back to their own couple seat is not "taken")
  if exists (
    select 1 from public.live_stream_seats
    where live_stream_id = p_stream_id and seat_number = p_seat and occupant_id <> auth.uid()
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

-- The host switches the couple seats on or off.
--   on : cp_seats = true and the host moves to the left couple seat (24) in the same step, keeping their speaking id and heartbeat, so the room never has a moment
--        without its host on a seat.
--   off: whoever sits on a couple seat is taken off it, cp_seats = false, and the host goes back to the first free ordinary seat (seat 1 when free).
create or replace function public.set_cp_seats(p_stream_id uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_host uuid;
  v_status text;
  v_mode text;
  v_count integer;
  v_locked integer[];
  v_row public.live_stream_seats%rowtype;
  v_seat integer;
begin
  if auth.uid() is null then raise exception 'Must be signed in'; end if;
  select host_id, status, mode, seat_count, locked_seats into v_host, v_status, v_mode, v_count, v_locked
    from public.live_streams where id = p_stream_id for update;
  if v_host is null then raise exception 'Stream not found'; end if;
  if v_host <> auth.uid() then raise exception 'Only the host can change the couple seats'; end if;
  if v_status <> 'live' then raise exception 'This stream is not live'; end if;
  if v_mode <> 'audio' then raise exception 'Couple seats are for audio rooms'; end if;

  select * into v_row from public.live_stream_seats where live_stream_id = p_stream_id and occupant_id = v_host;

  if p_on then
    -- anyone left on a couple seat from an earlier round is cleared first
    delete from public.live_stream_seats where live_stream_id = p_stream_id and seat_number in (24, 25) and occupant_id <> v_host;
    delete from public.live_stream_seats where live_stream_id = p_stream_id and occupant_id = v_host;
    insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, is_muted, agora_uid, last_heartbeat_at)
    values (p_stream_id, 24, v_host, coalesce(v_row.is_muted, false), v_row.agora_uid, now());
    update public.live_streams set cp_seats = true where id = p_stream_id;
  else
    delete from public.live_stream_seats where live_stream_id = p_stream_id and seat_number in (24, 25) and occupant_id <> v_host;
    update public.live_streams set cp_seats = false where id = p_stream_id;
    if v_row.occupant_id is not null and v_row.seat_number in (24, 25) then
      v_seat := null;
      for i in 1..v_count loop
        if not (i = any(coalesce(v_locked, '{}'))) and not exists (
          select 1 from public.live_stream_seats where live_stream_id = p_stream_id and seat_number = i
        ) then v_seat := i; exit; end if;
      end loop;
      delete from public.live_stream_seats where live_stream_id = p_stream_id and occupant_id = v_host;
      if v_seat is not null then
        insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, is_muted, agora_uid, last_heartbeat_at)
        values (p_stream_id, v_seat, v_host, v_row.is_muted, v_row.agora_uid, now());
      end if;
      -- no free seat: the host's own app puts them on one as soon as one frees up (it already does this whenever the host has no seat)
    end if;
  end if;
end;
$$;

-- set_seat_count, except that a room's couple seats (24 / 25 while cp_seats is on) are not "above the count".
create or replace function public.set_seat_count_v2(p_stream_id uuid, p_count integer)
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
       and s.mode = 'audio' and k.seat_number > p_count
       and not (s.cp_seats and k.seat_number in (24, 25));
  end if;
end;
$$;

revoke execute on function public.claim_cp_seat(uuid, integer) from public, anon;
revoke execute on function public.set_cp_seats(uuid, boolean) from public, anon;
revoke execute on function public.set_seat_count_v2(uuid, integer) from public, anon;
grant execute on function public.claim_cp_seat(uuid, integer) to authenticated;
grant execute on function public.set_cp_seats(uuid, boolean) to authenticated;
grant execute on function public.set_seat_count_v2(uuid, integer) to authenticated;
