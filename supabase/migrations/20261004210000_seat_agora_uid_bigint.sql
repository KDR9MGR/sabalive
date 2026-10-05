-- Why nobody else's voice lit up their seat: Agora assigns each device an UNSIGNED 32-bit
-- uid, and about half of them are above 2,147,483,647 (the largest value in production is
-- 4,287,323,012). live_stream_seats.agora_uid and set_seat_agora_uid were created as
-- 32-bit signed integers, so for those users the call failed with "value out of range for
-- type integer" — silently, because the app fires it and moves on — and their seat never
-- carried the uid that Agora's volume reports are matched against. Your own voice still
-- worked because Agora reports it as uid 0, which needs no lookup.
--
-- The host's column was widened for exactly this reason on 2026-09-18
-- (20260918130000_host_agora_uid_bigint.sql); the seat column was missed.
-- Builds already in the field send the same call, so they are fixed by this alone.
alter table public.live_stream_seats alter column agora_uid type bigint;

drop function if exists public.set_seat_agora_uid(uuid, integer);

create function public.set_seat_agora_uid(p_stream_id uuid, p_uid bigint)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_stream_seats set agora_uid = p_uid
   where live_stream_id = p_stream_id and occupant_id = auth.uid()
     and agora_uid is distinct from p_uid;
end;
$$;
revoke execute on function public.set_seat_agora_uid(uuid, bigint) from public, anon;
grant execute on function public.set_seat_agora_uid(uuid, bigint) to authenticated;
