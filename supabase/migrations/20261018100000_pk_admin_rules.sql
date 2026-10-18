-- PK battle layer, part 3: the function behind the panel's "PK Battles -> Rules" editor. NEW function only; nothing existing changes.
--
-- pk_config (migration 20261017100000) is one row of rules. The panel saves it through this function, never by writing the table:
-- Master / Super Admin only (is_admin_or_above, like the Games and Lucky Box settings), the same ranges as the table's own checks, and an
-- audit log line. Rollback: supabase/rollbacks/20261018100000_down.sql

set local lock_timeout = '5s';

create or replace function public.admin_set_pk_config(
  p_invite_durations integer[],
  p_random_duration integer,
  p_forfeit_grace_seconds integer,
  p_invites_per_minute integer,
  p_random_queue_seconds integer
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_len integer;
  v_d integer;
begin
  if not public.is_admin_or_above() then
    raise exception 'Not allowed';
  end if;

  v_len := coalesce(cardinality(p_invite_durations), 0);
  if v_len < 1 or v_len > 8 then
    raise exception 'Give between 1 and 8 invite lengths';
  end if;
  foreach v_d in array p_invite_durations loop
    if v_d is null or v_d < 30 or v_d > 3600 then
      raise exception 'Each invite length must be between 30 and 3600 seconds';
    end if;
  end loop;
  if (select count(distinct x) from unnest(p_invite_durations) as x) <> v_len then
    raise exception 'The same invite length is listed twice';
  end if;
  if p_random_duration is null or p_random_duration < 30 or p_random_duration > 3600 then
    raise exception 'The random PK length must be between 30 and 3600 seconds';
  end if;
  if p_forfeit_grace_seconds is null or p_forfeit_grace_seconds < 45 or p_forfeit_grace_seconds > 85 then
    raise exception 'The forfeit grace must be between 45 and 85 seconds';
  end if;
  if p_invites_per_minute is null or p_invites_per_minute < 1 or p_invites_per_minute > 60 then
    raise exception 'Invites per minute must be between 1 and 60';
  end if;
  if p_random_queue_seconds is null or p_random_queue_seconds < 10 or p_random_queue_seconds > 120 then
    raise exception 'The random search expiry must be between 10 and 120 seconds';
  end if;

  update public.pk_config
     set invite_durations = (select array_agg(x order by x) from unnest(p_invite_durations) as x),
         random_duration = p_random_duration,
         forfeit_grace_seconds = p_forfeit_grace_seconds,
         invites_per_minute = p_invites_per_minute,
         random_queue_seconds = p_random_queue_seconds,
         updated_at = now()
   where id;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'PK rules changed', format('lengths %s, random %s s, grace %s s, %s invites/min, search %s s',
          p_invite_durations, p_random_duration, p_forfeit_grace_seconds, p_invites_per_minute, p_random_queue_seconds), 'info');
end;
$$;
revoke execute on function public.admin_set_pk_config(integer[], integer, integer, integer, integer) from public, anon;
grant execute on function public.admin_set_pk_config(integer[], integer, integer, integer, integer) to authenticated;
