-- Down script for supabase/migrations/20261021110000_audio_seat_requests_switch.sql
-- Applied BY HAND only, when that migration has to be undone. It puts back the two function bodies of migration 20261019100000 exactly as they were
-- (set_seat_requests_v2 asks no switch; request_seat_v2 makes a request when the room asks or a battle is on) and drops the helper.
-- Nothing else changes: the panel flag `audio_seat_requests` stays in app_config.feature_flags but nothing reads it any more.
begin;
set local lock_timeout = '5s';

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

drop function if exists public.audio_seat_requests_on();

commit;
