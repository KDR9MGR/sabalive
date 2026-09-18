-- A lightweight heartbeat for a seat holder — plain UPDATE, unlike
-- claim_seat (delete+insert, which would fire a Realtime insert event to
-- every watcher on every heartbeat tick if reused for this).
create function public.heartbeat_seat(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_stream_seats set last_heartbeat_at = now()
  where live_stream_id = p_stream_id and occupant_id = auth.uid();
end;
$$;
revoke execute on function public.heartbeat_seat(uuid) from public;
grant execute on function public.heartbeat_seat(uuid) to authenticated;
