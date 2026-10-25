-- Levels: edit ANY level's XP freely, later levels move up with it.
--
-- admin_save_track_level (20261004100000) refuses an XP that is not strictly between the neighbours, so raising level 5 above level 6's XP
-- needed every later level edited first. admin_save_track_level_v2 adds one switch, p_shift: when the new XP would reach the next level, every
-- LATER level moves up by the same amount (so each keeps its gap to the one before it) instead of the edit being refused. Lowering a level never
-- needs a shift, and a level can still never be at or below the one before it (edit that one first). Everything else is the same as the old
-- function: level 1 is always 0 XP, the next new level is max + 1, only a Master/Super Admin with manage_levels, and everyone is re-levelled at once.
--
-- Additive: a new function, the old one stays (and keeps its strict rule). Rollback: supabase/rollbacks/20261025110000_down.sql.
create or replace function public.admin_save_track_level_v2(
  p_track text, p_level integer, p_xp integer, p_image_url text default null, p_shift boolean default false
) returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_prev integer;
  v_next integer;
  v_max integer;
  v_old integer;
  v_delta bigint;
  v_shifted integer := 0;
begin
  if not public.staff_cap_on('manage_levels') then
    raise exception 'Only a Master or Super Admin can edit levels';
  end if;
  if p_track not in ('wealth', 'charm') then raise exception 'Track must be wealth or charm'; end if;
  if p_level is null or p_level < 1 then raise exception 'Level must be 1 or more'; end if;
  if p_xp is null or p_xp < 0 then raise exception 'XP must be 0 or more'; end if;
  if p_level = 1 and p_xp <> 0 then raise exception 'Level 1 always needs 0 XP'; end if;

  select max(level) into v_max from public.track_levels where track = p_track;
  if p_level > coalesce(v_max, 0) + 1 then
    raise exception 'The next new level is %', coalesce(v_max, 0) + 1;
  end if;
  select xp_required into v_prev from public.track_levels where track = p_track and level = p_level - 1;
  select xp_required into v_next from public.track_levels where track = p_track and level = p_level + 1;
  select xp_required into v_old from public.track_levels where track = p_track and level = p_level;

  if v_prev is not null and p_xp <= v_prev then
    raise exception 'Level % needs more than the % XP of level %', p_level, v_prev, p_level - 1;
  end if;

  if v_next is not null and p_xp >= v_next then
    if not coalesce(p_shift, false) then
      raise exception 'Level % needs less than the % XP of level %', p_level, v_next, p_level + 1;
    end if;
    -- v_next exists, so this level exists too (levels are contiguous): move every later level up by what this one moved
    v_delta := p_xp::bigint - v_old;
    if (select max(xp_required) from public.track_levels where track = p_track and level > p_level) + v_delta > 2000000000 then
      raise exception 'The later levels would go past 2,000,000,000 XP';
    end if;
    update public.track_levels set xp_required = xp_required + v_delta::integer
     where track = p_track and level > p_level;
    get diagnostics v_shifted = row_count;
  end if;

  insert into public.track_levels (track, level, xp_required, image_url)
  values (p_track, p_level, p_xp, nullif(trim(coalesce(p_image_url, '')), ''))
  on conflict (track, level) do update
    set xp_required = excluded.xp_required, image_url = excluded.image_url;

  if v_old is distinct from p_xp or v_shifted > 0 then
    perform public.recompute_track_levels(p_track);
  end if;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'levels.saved',
          p_track || ' level ' || p_level || case when v_shifted > 0 then ' (' || v_shifted || ' later levels moved up)' else '' end,
          'info');
  return v_shifted;
end;
$$;
revoke execute on function public.admin_save_track_level_v2(text, integer, integer, text, boolean) from public, anon;
grant execute on function public.admin_save_track_level_v2(text, integer, integer, text, boolean) to authenticated;
