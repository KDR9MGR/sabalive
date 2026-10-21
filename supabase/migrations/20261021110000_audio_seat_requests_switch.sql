-- Audio lives and audio PK: no seat requests (owner, 2026-10-21: "for audio live and audio PK no request needed; video is fine"). A switch in the admin
-- panel (Application Configuration -> Release controls -> "Audio seat requests", the `audio_seat_requests` flag in app_config.feature_flags) decides, and it is OFF
-- by default. Nothing is dropped and no signature changes: two NEW-style functions of migration 20261019100000 get new bodies, one helper is added.
--
-- While the switch is OFF:
--   * request_seat_v2 (what the apps on phones call when a battle is on or the room "asks") does not make a request: it seats the viewer at once on the
--     first free seat the host has not locked, through claim_seat, and answers with an already-approved record. So even builds that always ask in a PK
--     battle let people sit straight away. (The seat is the first free one, not necessarily the one tapped: the call carries no seat number.)
--   * set_seat_requests_v2 refuses to turn "ask before someone sits" ON. The host's app calls it at the start of every audio room; a refusal makes the
--     app treat the server as one without requests, which hides the host's "Ask before someone sits" switch and leaves seats self-serve.
-- While the switch is ON everything behaves exactly as before (rooms may ask, a battle always asks, the host approves).
-- VIDEO seat requests (request_pk_seat / video_seat_requests) are another function and are not touched.
-- Rollback: supabase/rollbacks/20261021110000_down.sql

-- ------------------------------------------------------------------------------------------------------------- the switch
create or replace function public.audio_seat_requests_on()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select feature_flags -> 'audio_seat_requests' = 'true'::jsonb from public.app_config limit 1), false);
$$;
revoke execute on function public.audio_seat_requests_on() from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------------------ set_seat_requests_v2
create or replace function public.set_seat_requests_v2(p_stream_id uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_on is null then
    raise exception 'Say whether seat requests are on';
  end if;
  if p_on and not public.audio_seat_requests_on() then
    raise exception 'Seat requests are switched off for audio rooms';
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

-- ---------------------------------------------------------------------------------------------------------- request_seat_v2
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
  v_count integer;
  v_locked integer[];
  v_denied text;
  v_row public.pk_seat_requests;
  v_seat integer;
  v_try integer := 0;
  v_on boolean := public.audio_seat_requests_on();
begin
  if v_me is null then
    raise exception 'Must be signed in to request a seat';
  end if;
  if public.is_ghost(v_me) then
    raise exception 'This account can only watch';
  end if;

  select status, host_id, mode, seat_requests, seat_count, coalesce(locked_seats, '{}')
    into v_status, v_host, v_mode, v_asks, v_count, v_locked
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
  if v_on and not v_asks and not exists (
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

  if not v_on then
    -- requests are switched off for audio rooms: seat the viewer now, on the first free seat the host has not locked (claim_seat holds every
    -- other rule: bans, a taken seat). Two people asking at once can pick the same seat: the loser tries the next free one.
    loop
      v_try := v_try + 1;
      select s into v_seat
      from generate_series(1, v_count) s
      where not (s = any(v_locked))
        and not exists (select 1 from public.live_stream_seats q where q.live_stream_id = p_stream_id and q.seat_number = s)
      order by s
      limit 1;
      if v_seat is null then
        raise exception 'This room has no free seat';
      end if;
      begin
        perform public.claim_seat(p_stream_id, v_seat);
        exit;
      exception when others then
        if v_try >= 3 then
          raise;
        end if;
      end;
    end loop;
    insert into public.pk_seat_requests (live_stream_id, requester_id, status, decided_at)
    values (p_stream_id, v_me, 'approved', now())
    returning * into v_row;
    return v_row;
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
