-- "Watching now" was showing the same viewer twice. Root cause:
-- join_live_stream always did a bare INSERT with no cleanup first — a
-- viewer whose app was killed/backgrounded without a clean dispose (so
-- leave_live_stream never ran) leaves their live_stream_viewers row stuck
-- open (left_at null). If they reopen the same stream before the
-- finalize_stale_presence cron's 90-150s sweep catches that stale row, a
-- SECOND open row gets inserted for the same (stream, viewer) pair, and
-- currentViewers() (filtered on left_at is null) shows both. Same fix
-- shape as claim_seat already uses for seats: close out any dangling open
-- session for this viewer on this stream before inserting the new one, so
-- there's only ever at most one open row per (stream, viewer) at a time.
create or replace function public.join_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Must be signed in to join a live stream';
  end if;
  update public.live_stream_viewers
  set left_at = now()
  where live_stream_id = p_stream_id and viewer_id = auth.uid() and left_at is null;
  insert into public.live_stream_viewers (live_stream_id, viewer_id)
  values (p_stream_id, auth.uid());
  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
  values (p_stream_id, auth.uid(), 'joined the live stream', 'system');
end;
$$;
