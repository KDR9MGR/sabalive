-- A host disappearing from their own audio room: the clean-up that frees seats whose
-- holder stopped sending heartbeats (every minute, after 90 s) also freed the HOST's
-- seat whenever the host's app wasn't heartbeating that particular seat — an older app
-- build, or a phone whose timers were paused — even though the host was plainly still
-- live (their stream heartbeat, which every build sends, was fresh). The room then
-- showed no host, and sometimes a guest took seat 1 so the host could not sit back down.
--
-- The host's seat is now only freed once the stream itself has stopped heartbeating,
-- i.e. when the live is really over. Everyone else's seats are swept exactly as before.
-- Server-side, so it also helps people still on the older Play build.
create or replace function public.finalize_stale_presence()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.live_stream_seats ss
   where ss.last_heartbeat_at < now() - interval '90 seconds'
     and not exists (
       select 1 from public.live_streams s
        where s.id = ss.live_stream_id
          and s.host_id = ss.occupant_id
          and s.status = 'live'
          and s.last_heartbeat_at > now() - interval '90 seconds'
     );

  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
  select distinct v.live_stream_id, v.viewer_id, 'left the live stream', 'system'
    from public.live_stream_viewers v
    join public.live_streams s on s.id = v.live_stream_id and s.status = 'live'
   where v.left_at is null
     and v.last_heartbeat_at < now() - interval '90 seconds';

  update public.live_stream_viewers set left_at = now()
  where left_at is null and last_heartbeat_at < now() - interval '90 seconds';
end;
$$;
