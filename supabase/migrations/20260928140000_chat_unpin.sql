-- Pinning a notice already worked (a host inserting their own row with
-- pinned: true is covered by the existing INSERT policy). Unpinning needs
-- an UPDATE, and live_chat_messages has no UPDATE policy at all — RLS
-- denies by default with none present. Rather than add a raw client
-- UPDATE policy (which would need to also stop a non-host or a random
-- message sender from toggling someone else's pin), this goes through a
-- SECURITY DEFINER RPC instead, same pattern as every other moderation
-- action in this schema (host_set_seat_mute, set_seat_lock, etc.) — only
-- the stream's host can pin/unpin, and only messages belonging to that
-- stream.
create function public.set_chat_pin(p_message_id bigint, p_pinned boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_stream_id uuid;
begin
  select live_stream_id into v_stream_id
  from public.live_chat_messages where id = p_message_id;
  if v_stream_id is null then
    raise exception 'Message not found';
  end if;
  if not exists (
    select 1 from public.live_streams
    where id = v_stream_id and host_id = auth.uid()
  ) then
    raise exception 'Only the host can do this';
  end if;
  update public.live_chat_messages set pinned = p_pinned where id = p_message_id;
end;
$$;
revoke execute on function public.set_chat_pin(bigint, boolean) from public;
grant execute on function public.set_chat_pin(bigint, boolean) to authenticated;
