-- PK battle layer, part 4: (1) "ask the host for a seat" for audio rooms, in a PK battle and everywhere else the host wants it, and
-- (2) "End PK" as giving up (the other host wins). NEW column, NEW functions only; nothing existing changes.
--
-- (1) Seats of an audio room are self-serve (claim_seat). A host can now switch "ask before someone sits" on for their room
--     (live_streams.seat_requests, default off, so every existing room behaves as before) and a battle always asks. The request side
--     is request_seat_v2; approve_pk_seat_request / decline_pk_seat_request (migration 20260927100000) look only at the host, so they
--     already work for any live. claim_seat is NOT changed: apps that do not know the setting (the builds on Play today) still sit at
--     once, so this is a courtesy the host's own app and the newer viewer apps honour, not a lock.
-- (2) pk_give_up_v2: the host who taps End PK in a live battle loses and the other host wins, reason 'forfeit' (the result screens
--     already explain a forfeit). finalize_pk_battle (score decides) stays for the final bell.
-- Rollback: supabase/rollbacks/20261019100000_down.sql

set local lock_timeout = '5s';

-- ------------------------------------------------------------------------------------------------------- the setting
alter table public.live_streams add column if not exists seat_requests boolean not null default false;

create or replace function public.set_seat_requests_v2(p_stream_id uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_on is null then
    raise exception 'Say whether seat requests are on';
  end if;
  update public.live_streams set seat_requests = p_on
  where id = p_stream_id and host_id = auth.uid() and mode = 'audio';
  if not found then
    raise exception 'Only the host of an audio room can do this';
  end if;
end;
$$;
revoke execute on function public.set_seat_requests_v2(uuid, boolean) from public, anon;
grant execute on function public.set_seat_requests_v2(uuid, boolean) to authenticated;

-- ------------------------------------------------------------------------------------------------------ request_seat_v2
create or replace function public.request_seat_v2(p_stream_id uuid)
returns public.pk_seat_requests
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_status text;
  v_host uuid;
  v_mode text;
  v_asks boolean;
  v_denied text;
  v_row public.pk_seat_requests;
begin
  if v_me is null then
    raise exception 'Must be signed in to request a seat';
  end if;
  if public.is_ghost(v_me) then
    raise exception 'This account can only watch';
  end if;

  select status, host_id, mode, seat_requests into v_status, v_host, v_mode, v_asks
  from public.live_streams where id = p_stream_id;
  if v_status is null then
    raise exception 'Stream not found';
  end if;
  if v_status <> 'live' then
    raise exception 'This stream is not live';
  end if;
  if v_mode <> 'audio' then
    raise exception 'Seat requests are for audio rooms';
  end if;
  if v_host = v_me then
    raise exception 'You are the host of this live';
  end if;
  if not v_asks and not exists (
    select 1 from public.pk_battles b
    where b.source is not null and b.status in ('accepted', 'live') and p_stream_id in (b.stream_a_id, b.stream_b_id)
  ) then
    raise exception 'This room does not ask for seat requests';
  end if;

  select message into v_denied from public.live_access_denied_reason(v_me, p_stream_id) limit 1;
  if v_denied is not null then
    raise exception '%', v_denied;
  end if;
  if exists (select 1 from public.live_stream_seat_bans where live_stream_id = p_stream_id and banned_id = v_me) then
    raise exception 'You have been removed from this room''s seats by the host';
  end if;
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
revoke execute on function public.request_seat_v2(uuid) from public, anon;
grant execute on function public.request_seat_v2(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------- clear_seat_requests_v2
-- The host's app calls this when it stops asking (the setting goes off, or a battle is over and the room does not ask on its own), so
-- requests nobody answered do not come back later.
create or replace function public.clear_seat_requests_v2(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()) then
    raise exception 'Only the host can do this';
  end if;
  update public.pk_seat_requests
  set status = 'cancelled', decided_at = now()
  where live_stream_id = p_stream_id and status = 'pending';
end;
$$;
revoke execute on function public.clear_seat_requests_v2(uuid) from public, anon;
grant execute on function public.clear_seat_requests_v2(uuid) to authenticated;

-- --------------------------------------------------------------------------------------------------------- pk_give_up_v2
create or replace function public.pk_give_up_v2(p_battle_id uuid)
returns public.pk_battles
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_row public.pk_battles;
begin
  select * into v_row from public.pk_battles where id = p_battle_id for update;
  if not found then
    raise exception 'Battle not found';
  end if;
  if v_row.status = 'finished' then
    return v_row; -- the final bell, the other host or the sweep got there first
  end if;
  if v_row.status <> 'live' then
    raise exception 'This battle is not live';
  end if;
  if v_row.source is null then
    raise exception 'This battle cannot be ended this way';
  end if;
  if v_me is null or v_me not in (v_row.host_a_id, v_row.host_b_id) then
    raise exception 'Only a host of this battle can end it';
  end if;

  update public.pk_battles
  set status = 'finished', ended_at = now(), end_reason = 'forfeit',
      winner = case when v_me = host_a_id then 'b' else 'a' end
  where id = p_battle_id
  returning * into v_row;
  return v_row;
end;
$$;
revoke execute on function public.pk_give_up_v2(uuid) from public, anon;
grant execute on function public.pk_give_up_v2(uuid) to authenticated;
