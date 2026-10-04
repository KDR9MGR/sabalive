-- Who is talking: a seat's holder tells the room which Agora uid is theirs, so every
-- screen can match the volume Agora reports for a uid to a seat and light it up.
-- (The host's uid is already on live_streams.host_agora_uid.)
alter table public.live_stream_seats add column if not exists agora_uid integer;

create or replace function public.set_seat_agora_uid(p_stream_id uuid, p_uid integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_stream_seats set agora_uid = p_uid
   where live_stream_id = p_stream_id and occupant_id = auth.uid()
     and agora_uid is distinct from p_uid;
end;
$$;
revoke execute on function public.set_seat_agora_uid(uuid, integer) from public, anon;
grant execute on function public.set_seat_agora_uid(uuid, integer) to authenticated;
