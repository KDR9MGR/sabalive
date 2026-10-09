-- Down script for supabase/migrations/20261009100000_instant_leave_and_faster_sweep.sql
-- Applied BY HAND only. Puts leave_live_stream and finalize_stale_presence back to their previous definitions
-- (20260925090000 and 20261004190000) and the sweep back to once a minute. Nothing the migration wrote needs undoing.
begin;
set local lock_timeout = '5s';

create or replace function public.leave_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_stream_viewers
  set left_at = now()
  where live_stream_id = p_stream_id and viewer_id = auth.uid() and left_at is null;
  if found then
    insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
    values (p_stream_id, auth.uid(), 'left the live stream', 'system');
  end if;
end;
$$;

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

select cron.schedule('finalize-stale-presence', '* * * * *', $sql$select public.finalize_stale_presence()$sql$);
drop index if exists public.live_stream_viewers_open_hb_idx;

commit;
