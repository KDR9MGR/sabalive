-- Down script for supabase/migrations/20261105100000_cp_seats.sql (CP / couple seats in an audio room)
-- Applied BY HAND only, when that migration has to be undone.
--
-- Cannot be undone by this script: the couple seats of lives that are on right now vanish (rooms drop back to their ordinary seats; the host is moved to an ordinary seat first),
-- and nothing remembers which rooms had them. A new app build that still calls claim_cp_seat / set_cp_seats / set_seat_count_v2 gets "function not found" for those calls:
-- the couple row simply stops working there, the rest of the room is unaffected.
begin;
set local lock_timeout = '5s';

-- put each host who is on a couple seat back on the first free ordinary seat, then clear every couple seat
do $$
declare
  r record;
  v_seat integer;
begin
  for r in
    select s.id as stream_id, s.host_id, s.seat_count, s.locked_seats, k.is_muted, k.agora_uid
      from public.live_streams s
      join public.live_stream_seats k on k.live_stream_id = s.id and k.occupant_id = s.host_id and k.seat_number in (24, 25)
  loop
    v_seat := null;
    for i in 1..r.seat_count loop
      if not (i = any(coalesce(r.locked_seats, '{}'))) and not exists (
        select 1 from public.live_stream_seats where live_stream_id = r.stream_id and seat_number = i
      ) then v_seat := i; exit; end if;
    end loop;
    delete from public.live_stream_seats where live_stream_id = r.stream_id and occupant_id = r.host_id;
    if v_seat is not null then
      insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, is_muted, agora_uid, last_heartbeat_at)
      values (r.stream_id, v_seat, r.host_id, r.is_muted, r.agora_uid, now());
    end if;
  end loop;
end $$;
delete from public.live_stream_seats where seat_number in (24, 25);

drop function if exists public.claim_cp_seat(uuid, integer);
drop function if exists public.set_cp_seats(uuid, boolean);
drop function if exists public.set_seat_count_v2(uuid, integer);
drop function if exists public.cp_seat_refusal(uuid, uuid, integer);
alter table public.live_streams drop column if exists cp_seats;

commit;
