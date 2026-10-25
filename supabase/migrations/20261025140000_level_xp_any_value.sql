-- Levels: any level can be given any XP, with NO relation to the level before or after it.
--
-- admin_save_track_level refuses an XP that is not strictly between the neighbours; admin_save_track_level_v2 (20261025110000) moved the later levels up
-- instead, but that stops at 2,000,000,000 XP, and production's Wealth ladder already ends there (level 100 = 2,000,000,000), so no Wealth edit that
-- needed a shift could ever succeed (Charm, which has room, worked). admin_save_track_level_v3 drops the neighbour rule altogether: the owner decides every
-- level's number by hand and nothing else moves.
--
-- What a level means with such numbers: a person is at the HIGHEST level whose XP they have reached (recompute_track_levels and award_wealth_charm_xp
-- both already read it that way: max(level) where xp_required <= xp). If level 5 needs less XP than level 4, a person with enough XP for 5 is at level 5
-- even though they have not reached level 4's number. Two levels may need the same XP.
--
-- Still true, because they are not about the neighbours: level 1 needs 0 XP (it is where everybody starts), the next NEW level is the highest + 1, XP is a
-- whole number from 0 to 2,147,483,647 (the column is an integer), only a Master / Super Admin with manage_levels, and everyone is re-levelled at once.
--
-- Additive: a new function; v1 and v2 stay. Rollback: supabase/rollbacks/20261025140000_down.sql.
create or replace function public.admin_save_track_level_v3(
  p_track text, p_level integer, p_xp integer, p_image_url text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_max integer;
  v_old integer;
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

  select xp_required into v_old from public.track_levels where track = p_track and level = p_level;
  insert into public.track_levels (track, level, xp_required, image_url)
  values (p_track, p_level, p_xp, nullif(trim(coalesce(p_image_url, '')), ''))
  on conflict (track, level) do update
    set xp_required = excluded.xp_required, image_url = excluded.image_url;

  if v_old is distinct from p_xp then
    perform public.recompute_track_levels(p_track);
  end if;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'levels.saved', p_track || ' level ' || p_level || ' = ' || p_xp || ' XP', 'info');
end;
$$;
revoke execute on function public.admin_save_track_level_v3(text, integer, integer, text) from public, anon;
grant execute on function public.admin_save_track_level_v3(text, integer, integer, text) to authenticated;
