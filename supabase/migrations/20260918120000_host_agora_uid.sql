-- Viewers need to know which Agora uid specifically belongs to the host,
-- now that seat-holders can also become broadcasters in the same channel
-- (video-mode seats, added earlier today) — onUserJoined alone no longer
-- reliably identifies "the host" once more than one broadcaster can join.
alter table public.live_streams add column host_agora_uid integer;

create function public.set_host_agora_uid(p_stream_id uuid, p_uid integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_streams set host_agora_uid = p_uid
  where id = p_stream_id and host_id = auth.uid();
end;
$$;
revoke execute on function public.set_host_agora_uid(uuid, integer) from public;
grant execute on function public.set_host_agora_uid(uuid, integer) to authenticated;
