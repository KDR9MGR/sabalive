-- Leaving a live should take effect at once, and a person who disappears without saying goodbye should go sooner.
--
-- Background: production data (7 days, 7,779 viewers who left) showed only 3.5% were closed within 10 s of their last
-- heartbeat; the median was 111 s. The app's exit calls never reached the server (fixed in the app), so the background
-- sweep did all the work: 90 s of silence + up to 60 s waiting for the next minutely run.
--
-- 1. leave_live_stream also frees the caller's seat, so ONE successful call is enough to disappear completely (viewer row,
--    seat, and the "left the live stream" notice written right now).
-- 2. A partial index over the open viewer rows, so the sweep (which now runs more often) stays cheap as the table grows.
-- 3. The sweep treats 75 s of silence (two missed 30 s heartbeats plus margin) as gone, and runs every 15 s instead of every
--    minute. It still never frees a live host's own seat while the stream's heartbeat is fresh.
-- Additive for old app builds: they call the same functions with the same arguments.

create or replace function public.leave_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.live_stream_seats
   where live_stream_id = p_stream_id and occupant_id = auth.uid();
  update public.live_stream_viewers
  set left_at = now()
  where live_stream_id = p_stream_id and viewer_id = auth.uid() and left_at is null;
  if found then
    insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
    values (p_stream_id, auth.uid(), 'left the live stream', 'system');
  end if;
end;
$$;

create index if not exists live_stream_viewers_open_hb_idx
  on public.live_stream_viewers (last_heartbeat_at) where left_at is null;

create or replace function public.finalize_stale_presence()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.live_stream_seats ss
   where ss.last_heartbeat_at < now() - interval '75 seconds'
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
     and v.last_heartbeat_at < now() - interval '75 seconds';

  update public.live_stream_viewers set left_at = now()
  where left_at is null and last_heartbeat_at < now() - interval '75 seconds';
end;
$$;

-- same job name: this replaces the schedule (pg_cron 1.5+ accepts "15 seconds"; production and staging run 1.6.4)
select cron.schedule('finalize-stale-presence', '15 seconds', $sql$select public.finalize_stale_presence()$sql$);
