-- Agora auto-assigns a 32-bit UNSIGNED uid (up to ~4.29 billion) when a
-- client joins with uid=0 (this app's pattern, since app user ids are
-- UUIDs, not native Agora uids), but Postgres `integer` is 32-bit SIGNED
-- (max ~2.1 billion). Any auto-assigned uid above that range made
-- set_host_agora_uid throw "value out of range for type integer" — and
-- since the client calls it fire-and-forget (RtcEngineEventHandler
-- callbacks aren't awaited), the failure was silent: host_agora_uid stayed
-- null forever, and viewers fell back to the old broken first-joined-wins
-- behavior the whole feature was built to replace.
drop function if exists public.set_host_agora_uid(uuid, integer);

alter table public.live_streams alter column host_agora_uid type bigint;

create function public.set_host_agora_uid(p_stream_id uuid, p_uid bigint)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.live_streams set host_agora_uid = p_uid
  where id = p_stream_id and host_id = auth.uid();
end;
$$;
revoke execute on function public.set_host_agora_uid(uuid, bigint) from public;
grant execute on function public.set_host_agora_uid(uuid, bigint) to authenticated;
