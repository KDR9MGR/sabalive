-- Live Monitor "Kill stream": a staff member who may watch lives from the panel (Super Admin always, a Master with
-- `monitor_lives` on, any other role only with `monitor_lives` explicitly granted: `staff_can_ghost_watch()`) can end
-- somebody's live right now.
--
-- Additive: ONE new function, no table or policy touched (so no app, old or new, can notice it). It does exactly what the
-- host's own End button and the stale-live cleanup do, `status = 'ended', ended_at = now()`, so the existing paths take over:
-- the live disappears from every feed, viewers' screens close through the Realtime watch on `live_streams`, `join_live_stream`
-- refuses new viewers, `heartbeat_stream` becomes a no-op, and the ended-at / Lucky Box / ranking code sees an ordinary ended live.
-- It only ever touches a row that is still 'live', so a double click or two staff at once do no harm.
-- Every use is written to `audit_logs` (action `live.killed`, severity warning) with the stream, host and title.
create or replace function public.admin_end_stream(p_stream_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_row record;
begin
  if v_actor is null or not coalesce(public.staff_can_ghost_watch(), false) then
    raise exception 'You do not have permission to end a live';
  end if;

  select id, host_id, title into v_row from public.live_streams where id = p_stream_id;
  if not found then
    raise exception 'That live does not exist';
  end if;

  update public.live_streams
     set status = 'ended', ended_at = now()
   where id = p_stream_id and status = 'live';

  if not found then
    -- already over (the host ended it, or the cleanup did): nothing to do, and nothing to log
    return jsonb_build_object('ended', false, 'reason', 'already_ended');
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (v_actor, 'live.killed', p_stream_id::text || ' host ' || v_row.host_id::text || ' "' || left(coalesce(v_row.title, ''), 120) || '"', 'warning');

  return jsonb_build_object('ended', true, 'host_id', v_row.host_id);
end;
$$;

revoke execute on function public.admin_end_stream(uuid) from public, anon;
grant execute on function public.admin_end_stream(uuid) to authenticated;
