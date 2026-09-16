-- Fixes streams getting stuck at status='live' forever when a host force-quits
-- or loses connection without tapping "End" — found ~10 such rows dating back
-- to Sept 6-9 testing, which is why the home/live feed showed "live" cards
-- that led nowhere (no one was actually broadcasting).
--
-- A heartbeat column + a scheduled cleanup job replaces the previous
-- assumption that endStream() is always called.

alter table public.live_streams
  add column last_heartbeat_at timestamptz not null default now();

-- One-time cleanup of the stale rows already sitting in the table.
update public.live_streams
set status = 'ended', ended_at = now()
where status = 'live';

create function public.heartbeat_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_streams
  set last_heartbeat_at = now()
  where id = p_stream_id and host_id = auth.uid() and status = 'live';
end;
$$;

revoke execute on function public.heartbeat_stream(uuid) from public;
grant execute on function public.heartbeat_stream(uuid) to authenticated;

-- Ends any stream whose host has missed several heartbeats (app killed,
-- crashed, or lost connectivity without a clean "End Live").
create function public.end_stale_live_streams()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_streams
  set status = 'ended', ended_at = now()
  where status = 'live' and last_heartbeat_at < now() - interval '90 seconds';
end;
$$;

create extension if not exists pg_cron with schema extensions;

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'end-stale-live-streams') then
    perform cron.schedule(
      'end-stale-live-streams',
      '* * * * *', -- every minute
      $sql$select public.end_stale_live_streams()$sql$
    );
  end if;
end;
$outer$;
