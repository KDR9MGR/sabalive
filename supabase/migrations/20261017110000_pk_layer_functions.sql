-- PK battle layer, part 2 of 2: NEW functions (nothing existing is replaced) and one new cron job.
--
-- invite_pk_opponent / respond_to_pk_invite / cancel_pk_battle / begin_pk_battle / finalize_pk_battle / send_pk_gift are NOT
-- touched: the legacy PK screens keep using them. The layer uses these new names:
--   pk_set_ready          the host's app says "this live has the PK layer on" (opponents must have it)
--   pk_invite_v2          invite a host in a live of the SAME kind (audio / video), with a length from pk_config
--   pk_eligible_following followed hosts who can be invited right now
--   pk_random_join/leave  the random pool: two searching hosts of the same kind are paired atomically
--   pk_begin_v2           starts an accepted battle; the length comes from the row, never from the phone
--   pk_forfeit_sweep      (cron, every 15 s) a host who left or went silent loses; only battles that have a source
-- Accept / decline / cancel / finish / gifts reuse the existing functions: they never look at the live's mode.
-- Rollback: supabase/rollbacks/20261017110000_down.sql

set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------- helpers
-- Is this live in a battle that has not finished? (internal)
create or replace function public.pk_stream_busy(p_stream uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.pk_battles
    where status not in ('finished', 'cancelled')
      and (stream_a_id = p_stream or stream_b_id = p_stream)
  );
$$;
revoke execute on function public.pk_stream_busy(uuid) from public, anon, authenticated;

-- Has either host blocked the other? (internal)
create or replace function public.pk_hosts_blocked(p_a uuid, p_b uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = p_a and blocked_id = p_b) or (blocker_id = p_b and blocked_id = p_a)
  );
$$;
revoke execute on function public.pk_hosts_blocked(uuid, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------------ pk_set_ready
create or replace function public.pk_set_ready(p_stream_id uuid, p_ready boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  update public.live_streams set pk_ready = coalesce(p_ready, false)
  where id = p_stream_id and host_id = v_me and status = 'live' and mode in ('audio', 'video');
  if not found then
    raise exception 'PK is only for your own audio or video live';
  end if;
end;
$$;
revoke execute on function public.pk_set_ready(uuid, boolean) from public, anon;
grant execute on function public.pk_set_ready(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------------------------- pk_invite_v2
create or replace function public.pk_invite_v2(p_my_stream_id uuid, p_target_stream_id uuid, p_duration_seconds integer)
returns public.pk_battles
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_my public.live_streams%rowtype;
  v_target public.live_streams%rowtype;
  v_cfg public.pk_config%rowtype;
  v_row public.pk_battles;
begin
  if v_me is null then
    raise exception 'Must be signed in to invite an opponent';
  end if;
  if p_my_stream_id = p_target_stream_id then
    raise exception 'Pick a different live to challenge';
  end if;

  -- Both lives are locked in a fixed order, so two invites that cross each other (or two hosts inviting the same
  -- third host) are decided one after the other: the second one sees the first one's row and is refused.
  perform pg_advisory_xact_lock(hashtextextended(least(p_my_stream_id::text, p_target_stream_id::text), 0));
  perform pg_advisory_xact_lock(hashtextextended(greatest(p_my_stream_id::text, p_target_stream_id::text), 0));

  select * into v_my from public.live_streams where id = p_my_stream_id;
  if not found or v_my.host_id <> v_me or v_my.status <> 'live' or v_my.mode not in ('audio', 'video') or not v_my.pk_ready then
    raise exception 'You must be live (audio or video) with PK switched on to invite an opponent';
  end if;

  select * into v_target from public.live_streams where id = p_target_stream_id;
  if not found or v_target.status <> 'live' or v_target.mode <> v_my.mode or not v_target.pk_ready
     or v_target.host_id = v_me then
    raise exception 'That streamer is not available for a PK battle right now';
  end if;
  if public.pk_hosts_blocked(v_me, v_target.host_id)
     or exists (select 1 from public.live_access_denied_reason(v_me, p_target_stream_id))
     or exists (select 1 from public.live_access_denied_reason(v_target.host_id, p_my_stream_id)) then
    raise exception 'That streamer is not available for a PK battle right now';
  end if;

  select * into v_cfg from public.pk_config limit 1;
  if p_duration_seconds is null or not (p_duration_seconds = any (v_cfg.invite_durations)) then
    raise exception 'Pick one of the PK lengths offered';
  end if;

  if (select count(*) from public.pk_battles
       where host_a_id = v_me and source is not null and invited_at > now() - interval '1 minute') >= v_cfg.invites_per_minute then
    raise exception 'Too many PK invites: wait a moment';
  end if;

  if public.pk_stream_busy(p_my_stream_id) or public.pk_stream_busy(p_target_stream_id) then
    raise exception 'One of these lives already has an active PK battle';
  end if;

  delete from public.pk_match_queue where stream_id in (p_my_stream_id, p_target_stream_id);

  insert into public.pk_battles (stream_a_id, stream_b_id, host_a_id, host_b_id, status, invited_at,
                                 duration_seconds, kind, source)
  values (p_my_stream_id, p_target_stream_id, v_me, v_target.host_id, 'invited', now(),
          p_duration_seconds, v_my.mode, 'invite')
  returning * into v_row;
  return v_row;
end;
$$;
revoke execute on function public.pk_invite_v2(uuid, uuid, integer) from public, anon;
grant execute on function public.pk_invite_v2(uuid, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------------------- pk_eligible_following
-- Hosts the caller follows who are live right now, in a live of the same kind, with PK on, not in a battle, not blocked.
create or replace function public.pk_eligible_following(p_my_stream_id uuid)
returns table (stream_id uuid, host_id uuid, title text, viewer_count integer, mode text)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_my public.live_streams%rowtype;
begin
  if v_me is null then
    return;
  end if;
  select * into v_my from public.live_streams where id = p_my_stream_id;
  if not found or v_my.host_id <> v_me or v_my.status <> 'live' or v_my.mode not in ('audio', 'video') then
    return;
  end if;
  return query
    select s.id, s.host_id, s.title, s.viewer_count, s.mode
    from public.follows f
    join public.live_streams s on s.host_id = f.followee_id
    where f.follower_id = v_me
      and s.status = 'live' and s.mode = v_my.mode and s.pk_ready and s.id <> p_my_stream_id
      and not public.pk_stream_busy(s.id)
      and not public.pk_hosts_blocked(v_me, s.host_id)
    order by s.viewer_count desc, s.started_at desc
    limit 50;
end;
$$;
revoke execute on function public.pk_eligible_following(uuid) from public, anon;
grant execute on function public.pk_eligible_following(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------- random pool
-- The app calls pk_random_join every 5 s while it searches. NULL = still searching. A battle (already 'accepted', random,
-- fixed length from pk_config) = matched: BOTH phones then run their 3 s countdown and call pk_begin_v2. The host who was
-- waiting learns about it through Realtime (the battle row has them as host A).
create or replace function public.pk_random_join(p_my_stream_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_my public.live_streams%rowtype;
  v_cfg public.pk_config%rowtype;
  v_partner public.pk_match_queue%rowtype;
  v_row public.pk_battles;
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;

  -- one pairing at a time: the pool is tiny and this is what makes "two hosts matched with the same third host" impossible
  perform pg_advisory_xact_lock(hashtextextended('pk_random_pool', 0));

  select * into v_my from public.live_streams where id = p_my_stream_id;
  if not found or v_my.host_id <> v_me or v_my.status <> 'live' or v_my.mode not in ('audio', 'video') or not v_my.pk_ready then
    raise exception 'You must be live (audio or video) with PK switched on to find an opponent';
  end if;
  if public.pk_stream_busy(p_my_stream_id) then
    raise exception 'You already have an active PK battle';
  end if;

  select * into v_cfg from public.pk_config limit 1;
  delete from public.pk_match_queue
  where seen_at < now() - make_interval(secs => v_cfg.random_queue_seconds)
     or not exists (select 1 from public.live_streams s where s.id = pk_match_queue.stream_id and s.status = 'live');

  select q.* into v_partner
  from public.pk_match_queue q
  join public.live_streams s on s.id = q.stream_id
  where q.kind = v_my.mode and q.stream_id <> p_my_stream_id and q.host_id <> v_me
    and s.status = 'live' and s.pk_ready
    and not public.pk_stream_busy(q.stream_id)
    and not public.pk_hosts_blocked(v_me, q.host_id)
  order by q.entered_at
  limit 1
  for update of q skip locked;

  if found then
    delete from public.pk_match_queue where stream_id in (p_my_stream_id, v_partner.stream_id);
    insert into public.pk_battles (stream_a_id, stream_b_id, host_a_id, host_b_id, status, invited_at, accepted_at,
                                   duration_seconds, kind, source)
    values (v_partner.stream_id, p_my_stream_id, v_partner.host_id, v_me, 'accepted', now(), now(),
            v_cfg.random_duration, v_my.mode, 'random')
    returning * into v_row;
    return to_jsonb(v_row);
  end if;

  insert into public.pk_match_queue (stream_id, host_id, kind)
  values (p_my_stream_id, v_me, v_my.mode)
  on conflict (stream_id) do update set seen_at = now();
  return null;
end;
$$;
revoke execute on function public.pk_random_join(uuid) from public, anon;
grant execute on function public.pk_random_join(uuid) to authenticated;

create or replace function public.pk_random_leave(p_my_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.pk_match_queue where stream_id = p_my_stream_id and host_id = auth.uid();
end;
$$;
revoke execute on function public.pk_random_leave(uuid) from public, anon;
grant execute on function public.pk_random_leave(uuid) to authenticated;

-- ------------------------------------------------------------------------------------------------ pk_begin_v2
-- Same contract as begin_pk_battle (either host may call, a second call is a harmless no-op) but the length is the one
-- stored at invite time: a phone can no longer pick its own.
create or replace function public.pk_begin_v2(p_battle_id uuid)
returns public.pk_battles
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_row public.pk_battles;
begin
  select * into v_row from public.pk_battles where id = p_battle_id for update;
  if not found then
    raise exception 'Battle not found';
  end if;
  if v_me is null or v_me not in (v_row.host_a_id, v_row.host_b_id) then
    raise exception 'Not authorized to start this battle';
  end if;
  if v_row.status = 'live' then
    return v_row;
  end if;
  if v_row.status <> 'accepted' then
    raise exception 'Battle is not ready to start';
  end if;
  if not exists (select 1 from public.live_streams where id = v_row.stream_a_id and status = 'live')
     or not exists (select 1 from public.live_streams where id = v_row.stream_b_id and status = 'live') then
    update public.pk_battles set status = 'cancelled', ended_at = now(), end_reason = 'cancelled' where id = p_battle_id;
    raise exception 'This battle can no longer start: a live has ended';
  end if;

  update public.pk_battles
  set status = 'live', started_at = now(), ends_at = now() + make_interval(secs => v_row.duration_seconds)
  where id = p_battle_id
  returning * into v_row;
  return v_row;
end;
$$;
revoke execute on function public.pk_begin_v2(uuid) from public, anon;
grant execute on function public.pk_begin_v2(uuid) to authenticated;

-- ------------------------------------------------------------------------------------------ pk_forfeit_sweep
-- A live battle (that has a source: never a legacy one) whose host ended the live, or whose live has been silent for longer
-- than pk_config.forfeit_grace_seconds (the host's app stamps last_heartbeat_at every 30 s), is finished at once: the host
-- who is still there wins. If both are gone the score decides. Tiny query on the live battles only.
create or replace function public.pk_forfeit_sweep()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_grace integer;
  r record;
begin
  select forfeit_grace_seconds into v_grace from public.pk_config limit 1;
  v_grace := coalesce(v_grace, 60);

  for r in
    select b.id,
           (sa.status <> 'live' or sa.last_heartbeat_at < now() - make_interval(secs => v_grace)) as a_gone,
           (sb.status <> 'live' or sb.last_heartbeat_at < now() - make_interval(secs => v_grace)) as b_gone
    from public.pk_battles b
    join public.live_streams sa on sa.id = b.stream_a_id
    join public.live_streams sb on sb.id = b.stream_b_id
    where b.status = 'live' and b.source is not null
      and (sa.status <> 'live' or sb.status <> 'live'
           or sa.last_heartbeat_at < now() - make_interval(secs => v_grace)
           or sb.last_heartbeat_at < now() - make_interval(secs => v_grace))
    for update of b skip locked
  loop
    update public.pk_battles
    set status = 'finished', ended_at = now(),
        end_reason = case when r.a_gone <> r.b_gone then 'forfeit' else 'time' end,
        winner = case
                   when r.a_gone and not r.b_gone then 'b'
                   when r.b_gone and not r.a_gone then 'a'
                   when score_a > score_b then 'a'
                   when score_b > score_a then 'b'
                   else 'draw'
                 end
    where id = r.id and status = 'live';
  end loop;
end;
$$;
revoke execute on function public.pk_forfeit_sweep() from public, anon, authenticated;

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'pk-forfeit-sweep') then
    perform cron.schedule('pk-forfeit-sweep', '15 seconds', $sql$select public.pk_forfeit_sweep()$sql$);
  end if;
end;
$outer$;
