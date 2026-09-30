-- Real "X joined" / "X left" chat events. live_chat_messages.kind already
-- had 'system' as an allowed value from day one, but nothing ever used it —
-- the only "has joined the Chatroom" lines anywhere were hardcoded mock seed
-- data in pk_battle_screen.dart, not real events. The client-side chat
-- renderer already resolves sender_id -> profile name for every line, so the
-- body just needs the action text, not the name itself.
create or replace function public.join_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Must be signed in to join a live stream';
  end if;
  insert into public.live_stream_viewers (live_stream_id, viewer_id)
  values (p_stream_id, auth.uid());
  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
  values (p_stream_id, auth.uid(), 'joined the live stream', 'system');
end;
$$;

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
