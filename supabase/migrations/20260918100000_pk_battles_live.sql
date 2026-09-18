-- Turns pk_battles from 100%-dead schema (nothing read or wrote it; INSERT
-- was staff-only) into the real two-host PK battle backend. Replaces the
-- fully client-side fake score and the ad hoc, unpersisted Realtime
-- Broadcast mirror (pk-score-<streamId>) entirely — postgres_changes on
-- this table is now the single source of truth for host and viewer alike.

alter table public.pk_battles
  add column host_a_id uuid references public.profiles (id),
  add column host_b_id uuid references public.profiles (id),
  add column ends_at timestamptz,
  add column invited_at timestamptz not null default now(),
  add column accepted_at timestamptz,
  add column winner text check (winner in ('a', 'b', 'draw'));

-- started_at must only ever mean "when did LIVE begin" — wrong to default
-- it at invite-row-creation time.
alter table public.pk_battles alter column started_at drop default;
alter table public.pk_battles alter column started_at drop not null;

update public.pk_battles set host_a_id = (select host_id from public.live_streams where id = stream_a_id) where host_a_id is null;
update public.pk_battles set host_b_id = (select host_id from public.live_streams where id = stream_b_id) where host_b_id is null;

-- 7-state machine, replacing ('active','ended'). 'waiting' and 'countdown'
-- are reserved for possible future use — no RPC below ever inserts either
-- value; WAITING is represented as "no non-terminal row references my
-- stream" and the brief COUNTDOWN beat is a client-local animation between
-- ACCEPTED and LIVE.
alter table public.pk_battles drop constraint pk_battles_status_check;
alter table public.pk_battles
  add constraint pk_battles_status_check
  check (status in ('waiting', 'invited', 'accepted', 'countdown', 'live', 'finished', 'cancelled'));
alter table public.pk_battles alter column status set default 'invited';

create index pk_battles_host_a_idx on public.pk_battles (host_a_id);
create index pk_battles_host_b_idx on public.pk_battles (host_b_id);
create index pk_battles_active_idx on public.pk_battles (status) where status not in ('finished', 'cancelled');

alter publication supabase_realtime add table public.pk_battles;

-- Every write below goes through a SECURITY DEFINER RPC, the same way
-- wallets/gift_transactions have no client write path at all — tighter
-- than calls' "either participant updates the row directly" precedent,
-- because a PK battle gates real gift/coin mutations and is publicly
-- visible, not a private signal between two trusted parties.
drop policy "Staff start PK battles" on public.pk_battles;
drop policy "Involved hosts and staff manage a PK battle" on public.pk_battles;
-- "PK battles are publicly viewable" (select, using (true)) stays as-is.
revoke insert, update, delete on public.pk_battles from authenticated;

-- ---------------------------------------------------------- invite_pk_opponent
-- Eligibility is intentionally narrow: both streams must be mode='pk' and
-- currently live. Keeps the whole feature inside the two PK screens — it
-- never has to interrupt a video/audio host's broadcast.
create function public.invite_pk_opponent(p_my_stream_id uuid, p_target_stream_id uuid)
returns public.pk_battles
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_my_stream public.live_streams%rowtype;
  v_target public.live_streams%rowtype;
  v_row public.pk_battles;
begin
  if v_me is null then
    raise exception 'Must be signed in to invite an opponent';
  end if;
  if p_my_stream_id = p_target_stream_id then
    raise exception 'Pick a different stream to challenge';
  end if;

  select * into v_my_stream from public.live_streams where id = p_my_stream_id;
  if not found or v_my_stream.host_id <> v_me or v_my_stream.status <> 'live' or v_my_stream.mode <> 'pk' then
    raise exception 'You must be live in PK mode to invite an opponent';
  end if;

  select * into v_target from public.live_streams where id = p_target_stream_id;
  if not found or v_target.status <> 'live' or v_target.mode <> 'pk' then
    raise exception 'That streamer is not available for a PK battle right now';
  end if;
  if v_target.host_id = v_me then
    raise exception 'You cannot challenge yourself';
  end if;

  if exists (
    select 1 from public.pk_battles
    where status not in ('finished', 'cancelled')
      and (stream_a_id in (p_my_stream_id, p_target_stream_id)
           or stream_b_id in (p_my_stream_id, p_target_stream_id))
  ) then
    raise exception 'One of these streams already has an active PK battle';
  end if;

  insert into public.pk_battles (stream_a_id, stream_b_id, host_a_id, host_b_id, status, invited_at)
  values (p_my_stream_id, p_target_stream_id, v_me, v_target.host_id, 'invited', now())
  returning * into v_row;

  return v_row;
end;
$$;
revoke execute on function public.invite_pk_opponent(uuid, uuid) from public;
grant execute on function public.invite_pk_opponent(uuid, uuid) to authenticated;

-- ------------------------------------------------------- respond_to_pk_invite
create function public.respond_to_pk_invite(p_battle_id uuid, p_accept boolean)
returns public.pk_battles
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_row public.pk_battles;
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  select * into v_row from public.pk_battles where id = p_battle_id for update;
  if not found then
    raise exception 'Invite not found';
  end if;
  if v_row.host_b_id <> v_me then
    raise exception 'This invite is not addressed to you';
  end if;
  if v_row.status <> 'invited' then
    raise exception 'This invite is no longer active';
  end if;

  if p_accept then
    -- Re-validate both streams are still live — either host may have
    -- dropped since invite_pk_opponent's own check.
    if not exists (select 1 from public.live_streams where id = v_row.stream_a_id and status = 'live')
       or not exists (select 1 from public.live_streams where id = v_row.stream_b_id and status = 'live') then
      update public.pk_battles set status = 'cancelled', ended_at = now() where id = p_battle_id;
      raise exception 'This battle can no longer be joined — a stream has ended';
    end if;
    update public.pk_battles set status = 'accepted', accepted_at = now()
    where id = p_battle_id returning * into v_row;
  else
    update public.pk_battles set status = 'cancelled', ended_at = now()
    where id = p_battle_id returning * into v_row;
  end if;
  return v_row;
end;
$$;
revoke execute on function public.respond_to_pk_invite(uuid, boolean) from public;
grant execute on function public.respond_to_pk_invite(uuid, boolean) to authenticated;

-- -------------------------------------------------------------- cancel_pk_battle
create function public.cancel_pk_battle(p_battle_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_row public.pk_battles;
begin
  select * into v_row from public.pk_battles where id = p_battle_id for update;
  if not found then
    return; -- already gone; idempotent
  end if;
  if v_row.status not in ('invited', 'accepted') then
    raise exception 'This battle can no longer be cancelled';
  end if;
  if v_me not in (v_row.host_a_id, v_row.host_b_id) and not public.is_admin_or_above() then
    raise exception 'Not authorized to cancel this battle';
  end if;
  update public.pk_battles set status = 'cancelled', ended_at = now() where id = p_battle_id;
end;
$$;
revoke execute on function public.cancel_pk_battle(uuid) from public;
grant execute on function public.cancel_pk_battle(uuid) to authenticated;

-- --------------------------------------------------------------- begin_pk_battle
-- Called by either client once their local "3…2…1" cosmetic countdown ends.
-- Idempotent: a second call from the other participant is a harmless no-op.
create function public.begin_pk_battle(p_battle_id uuid, p_duration_seconds integer default 300)
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
  if v_me not in (v_row.host_a_id, v_row.host_b_id) then
    raise exception 'Not authorized to start this battle';
  end if;
  if v_row.status = 'live' then
    return v_row;
  end if;
  if v_row.status <> 'accepted' then
    raise exception 'Battle is not ready to start';
  end if;
  if p_duration_seconds < 30 or p_duration_seconds > 3600 then
    raise exception 'Invalid battle duration';
  end if;
  if not exists (select 1 from public.live_streams where id = v_row.stream_a_id and status = 'live')
     or not exists (select 1 from public.live_streams where id = v_row.stream_b_id and status = 'live') then
    update public.pk_battles set status = 'cancelled', ended_at = now() where id = p_battle_id;
    raise exception 'This battle can no longer start — a stream has ended';
  end if;

  update public.pk_battles
  set status = 'live', started_at = now(), ends_at = now() + make_interval(secs => p_duration_seconds)
  where id = p_battle_id
  returning * into v_row;
  return v_row;
end;
$$;
revoke execute on function public.begin_pk_battle(uuid, integer) from public;
grant execute on function public.begin_pk_battle(uuid, integer) to authenticated;

-- ----------------------------------------------------------------- send_pk_gift
-- Reuses send_gift verbatim for every wallet/coin mutation — no second
-- wallet, no duplicated coin math — and additionally bumps the battle's
-- score with an atomic column-increment.
create function public.send_pk_gift(p_battle_id uuid, p_side text, p_gift_id uuid)
returns public.gift_transactions
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_battle public.pk_battles%rowtype;
  v_receiver uuid;
  v_receiver_stream uuid;
  v_tx public.gift_transactions;
begin
  if v_me is null then
    raise exception 'Must be signed in to send a gift';
  end if;
  if p_side not in ('a', 'b') then
    raise exception 'Invalid side';
  end if;

  select * into v_battle from public.pk_battles where id = p_battle_id;
  if not found then
    raise exception 'Battle not found';
  end if;
  if v_battle.status <> 'live' then
    raise exception 'This battle is not live';
  end if;
  if v_battle.ends_at is null or now() >= v_battle.ends_at then
    raise exception 'This battle has ended';
  end if;

  if p_side = 'a' then
    v_receiver := v_battle.host_a_id;
    v_receiver_stream := v_battle.stream_a_id;
  else
    v_receiver := v_battle.host_b_id;
    v_receiver_stream := v_battle.stream_b_id;
  end if;

  v_tx := public.send_gift(p_gift_id, v_receiver, v_receiver_stream);

  if p_side = 'a' then
    update public.pk_battles set score_a = score_a + v_tx.coins where id = p_battle_id;
  else
    update public.pk_battles set score_b = score_b + v_tx.coins where id = p_battle_id;
  end if;

  return v_tx;
end;
$$;
revoke execute on function public.send_pk_gift(uuid, text, uuid) from public;
grant execute on function public.send_pk_gift(uuid, text, uuid) to authenticated;

-- -------------------------------------------------------------- finalize_pk_battle
create function public.finalize_pk_battle(p_battle_id uuid)
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
  if v_row.status = 'finished' then
    return v_row;
  end if;
  if v_row.status <> 'live' then
    raise exception 'Battle is not live';
  end if;
  if v_me not in (v_row.host_a_id, v_row.host_b_id) and not public.is_admin_or_above() then
    raise exception 'Not authorized to end this battle';
  end if;

  update public.pk_battles
  set status = 'finished', ended_at = now(),
      winner = case when score_a > score_b then 'a' when score_b > score_a then 'b' else 'draw' end
  where id = p_battle_id
  returning * into v_row;
  return v_row;
end;
$$;
revoke execute on function public.finalize_pk_battle(uuid) from public;
grant execute on function public.finalize_pk_battle(uuid) to authenticated;

-- ----------------------------------------------------- finalize_expired_pk_battles
-- Mirrors end_stale_live_streams exactly: same pg_cron shape, same
-- every-minute precision ceiling already accepted elsewhere in this schema.
create function public.finalize_expired_pk_battles()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.pk_battles
  set status = 'finished', ended_at = now(),
      winner = case when score_a > score_b then 'a' when score_b > score_a then 'b' else 'draw' end
  where status = 'live' and ends_at is not null and now() >= ends_at;

  -- Sweeps invites/accepts nobody acted on, so a stale row doesn't
  -- permanently block re-inviting those two streams.
  update public.pk_battles set status = 'cancelled', ended_at = now()
  where status = 'invited' and invited_at < now() - interval '2 minutes';
  update public.pk_battles set status = 'cancelled', ended_at = now()
  where status = 'accepted' and accepted_at < now() - interval '2 minutes';
end;
$$;

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'finalize-expired-pk-battles') then
    perform cron.schedule(
      'finalize-expired-pk-battles',
      '* * * * *',
      $sql$select public.finalize_expired_pk_battles()$sql$
    );
  end if;
end;
$outer$;
