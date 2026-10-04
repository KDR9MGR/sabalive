-- Host chat controls that every viewer sees at once:
--   * Clear chat: stamps live_streams.chat_cleared_at; every screen in the room drops
--     the lines it has when that changes. (Nothing is deleted — it is a marker.)
--   * Room notice (pin / unpin): the notice itself lives on live_streams.pinned_notice
--     so every viewer — including someone who joins later — gets it with the stream row
--     and sees it change over the same Realtime channel the room already listens to.
--     It replaces pinning a chat line, which unpinning never reached viewers for.
-- Also: someone who joins a room sees only what is said from then on (the apps stop
-- loading the old chat); there is nothing to migrate for that.
alter table public.live_streams add column if not exists chat_cleared_at timestamptz;
alter table public.live_streams add column if not exists pinned_notice text;

create or replace function public.clear_live_chat(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_streams set chat_cleared_at = now()
   where id = p_stream_id and host_id = auth.uid() and status = 'live';
  if not found then raise exception 'Only the host can clear the chat'; end if;
end;
$$;
revoke execute on function public.clear_live_chat(uuid) from public, anon;
grant execute on function public.clear_live_chat(uuid) to authenticated;

-- p_notice null / blank = unpin
create or replace function public.set_live_notice(p_stream_id uuid, p_notice text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v text := nullif(trim(coalesce(p_notice, '')), '');
begin
  if v is not null and length(v) > 120 then raise exception 'A notice is at most 120 characters'; end if;
  update public.live_streams set pinned_notice = v
   where id = p_stream_id and host_id = auth.uid() and status = 'live';
  if not found then raise exception 'Only the host can pin a notice'; end if;
end;
$$;
revoke execute on function public.set_live_notice(uuid, text) from public, anon;
grant execute on function public.set_live_notice(uuid, text) to authenticated;
