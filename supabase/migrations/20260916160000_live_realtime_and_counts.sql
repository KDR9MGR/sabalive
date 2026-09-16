-- Three real bugs found testing host (Android) + viewer (iOS) simultaneously:
--
-- 1. Chat messages never arrived for either side in real time. Root cause:
--    live_chat_messages was never added to the supabase_realtime
--    publication, so Postgres never emits change events for it — the
--    Flutter subscriptions were correctly written but listening to a
--    stream that never fires. Rows were being inserted fine; nothing
--    ever told a listener about it.
-- 2. The host's viewer count never moved. Root cause: it was read from
--    Agora's onUserJoined/onUserOffline callbacks, but Agora's Live
--    Broadcasting channel profile does not report audience-role joins to
--    other participants by design (it doesn't scale to report every one
--    of potentially thousands of viewers) — only broadcaster-role joins
--    fire that event. The live_stream_viewers table already existed for
--    exactly this, with correct RLS, but nothing ever wrote to it.
-- 3. Like counts had the same "nothing increments a count column" gap.

alter publication supabase_realtime add table public.live_chat_messages;

-- ---------------------------------------------------------- viewer count
create function public.recompute_live_stream_viewer_count()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_stream_id uuid := coalesce(new.live_stream_id, old.live_stream_id);
begin
  update public.live_streams
  set viewer_count = (
    select count(*) from public.live_stream_viewers
    where live_stream_id = v_stream_id and left_at is null
  )
  where id = v_stream_id;
  return null;
end;
$$;

create trigger live_stream_viewers_recompute
  after insert or update or delete on public.live_stream_viewers
  for each row execute function public.recompute_live_stream_viewer_count();

-- A signed-in viewer logs their own join/leave; SECURITY DEFINER so the
-- trigger's update to live_streams (owned by the host, not the viewer)
-- isn't blocked by live_streams' own RLS.
create function public.join_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Must be signed in to join a live stream';
  end if;
  insert into public.live_stream_viewers (live_stream_id, viewer_id)
  values (p_stream_id, auth.uid());
end;
$$;

create function public.leave_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_stream_viewers
  set left_at = now()
  where live_stream_id = p_stream_id and viewer_id = auth.uid() and left_at is null;
end;
$$;

revoke execute on function public.join_live_stream(uuid) from public;
grant execute on function public.join_live_stream(uuid) to authenticated;
revoke execute on function public.leave_live_stream(uuid) from public;
grant execute on function public.leave_live_stream(uuid) to authenticated;

-- ------------------------------------------------------------ like count
create function public.recompute_live_stream_like_count()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_stream_id uuid := coalesce(new.live_stream_id, old.live_stream_id);
begin
  update public.live_streams
  set like_count = (
    select count(*) from public.stream_likes where live_stream_id = v_stream_id
  )
  where id = v_stream_id;
  return null;
end;
$$;

create trigger stream_likes_recompute
  after insert or delete on public.stream_likes
  for each row execute function public.recompute_live_stream_like_count();
