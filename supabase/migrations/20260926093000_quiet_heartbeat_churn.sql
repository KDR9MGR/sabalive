-- Investigating a reported "seat avatars flicker in and out" glitch:
-- heartbeat_viewer() does a plain UPDATE on live_stream_viewers (just
-- touching last_heartbeat_at every ~30s per viewer) but
-- recompute_live_stream_viewer_count() — which fires on every
-- insert/update/delete of that table — unconditionally wrote
-- live_streams.viewer_count even when the recomputed count was identical
-- to what was already there. An UPDATE that changes nothing still writes a
-- new row version and fires a Realtime broadcast to every watcher of that
-- stream, so every single viewer's heartbeat was causing a live_streams
-- UPDATE event (and a client-side setState/rebuild) across the whole room,
-- every ~30s, regardless of whether anyone actually joined or left.
-- heartbeat_seat() has the same shape against live_stream_seats, so the
-- same needless-rebuild pattern was hitting the seat grid specifically —
-- fixed client-side (only setState when the value actually changed);
-- this migration fixes the root cause for the viewer-count side.
create or replace function public.recompute_live_stream_viewer_count()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_stream_id uuid := coalesce(new.live_stream_id, old.live_stream_id);
  v_count integer;
begin
  select count(*) into v_count from public.live_stream_viewers
    where live_stream_id = v_stream_id and left_at is null;
  update public.live_streams
  set viewer_count = v_count
  where id = v_stream_id and viewer_count is distinct from v_count;
  return null;
end;
$$;
