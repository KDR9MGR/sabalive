-- Wealth and Charm levels become panel-managed, each with its own XP needed per
-- level and its own level image. Until now both tracks shared level_thresholds
-- (which still feeds the combined "LV X" badge and is left untouched).
--
-- The image is played full-screen in a live room when a user who has reached that
-- level (the highest level with an image at or below theirs, either track) joins —
-- the same way an entry effect plays. join_live_stream copies its url onto the
-- join row (live_chat_messages.level_image_url) so every screen in the room sees it.
-- Is this panel capability on for the caller? Super Admin always; a Master unless a
-- Super Admin switched that key off for the account (explicit false only — these
-- newer keys are on by default for a Master, so the SQL role_baseline() isn't used).
create or replace function public.staff_cap_on(p_key text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select case public.current_staff_role()
    when 'super_admin' then true
    when 'admin' then coalesce(
      nullif((select s.permissions ->> p_key from public.staff_roles s where s.user_id = auth.uid()), '')::boolean,
      true)
    else false
  end;
$$;
revoke execute on function public.staff_cap_on(text) from public, anon;
grant execute on function public.staff_cap_on(text) to authenticated;

create table public.track_levels (
  track text not null check (track in ('wealth', 'charm')),
  level integer not null check (level >= 1),
  xp_required integer not null check (xp_required >= 0),
  image_url text,
  primary key (track, level)
);

insert into public.track_levels (track, level, xp_required)
select t.track, l.level, l.xp_required
  from public.level_thresholds l
 cross join (values ('wealth'), ('charm')) as t(track);

alter table public.track_levels enable row level security;
create policy "Track levels are viewable by everyone"
  on public.track_levels for select using (true);

-- every profile's level for a track, from its xp (after the thresholds change)
create or replace function public.recompute_track_levels(p_track text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_track = 'wealth' then
    update public.profiles p set wealth_level = coalesce(
      (select max(level) from public.track_levels where track = 'wealth' and xp_required <= p.wealth_xp), 1)
     where p.wealth_level is distinct from coalesce(
      (select max(level) from public.track_levels where track = 'wealth' and xp_required <= p.wealth_xp), 1);
  else
    update public.profiles p set charm_level = coalesce(
      (select max(level) from public.track_levels where track = 'charm' and xp_required <= p.charm_xp), 1)
     where p.charm_level is distinct from coalesce(
      (select max(level) from public.track_levels where track = 'charm' and xp_required <= p.charm_xp), 1);
  end if;
end;
$$;
revoke execute on function public.recompute_track_levels(text) from public, anon, authenticated;

-- Edit (or add the next) level: its XP and image. XP must stay strictly between its
-- neighbours' (level 1 is always 0), so levels can never get out of order.
create or replace function public.admin_save_track_level(
  p_track text, p_level integer, p_xp integer, p_image_url text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_prev integer;
  v_next integer;
  v_max integer;
  v_old integer;
begin
  if not public.staff_cap_on('manage_levels') then
    raise exception 'Only a Master or Super Admin can edit levels';
  end if;
  if p_track not in ('wealth', 'charm') then raise exception 'Track must be wealth or charm'; end if;
  if p_level < 1 then raise exception 'Level must be 1 or more'; end if;
  if p_xp is null or p_xp < 0 then raise exception 'XP must be 0 or more'; end if;
  if p_level = 1 and p_xp <> 0 then raise exception 'Level 1 always needs 0 XP'; end if;

  select max(level) into v_max from public.track_levels where track = p_track;
  if p_level > coalesce(v_max, 0) + 1 then
    raise exception 'The next new level is %', coalesce(v_max, 0) + 1;
  end if;
  select xp_required into v_prev from public.track_levels where track = p_track and level = p_level - 1;
  select xp_required into v_next from public.track_levels where track = p_track and level = p_level + 1;
  if v_prev is not null and p_xp <= v_prev then
    raise exception 'Level % needs more than the % XP of level %', p_level, v_prev, p_level - 1;
  end if;
  if v_next is not null and p_xp >= v_next then
    raise exception 'Level % needs less than the % XP of level %', p_level, v_next, p_level + 1;
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
  values (auth.uid(), 'levels.saved', p_track || ' level ' || p_level, 'info');
end;
$$;
revoke execute on function public.admin_save_track_level(text, integer, integer, text) from public, anon;
grant execute on function public.admin_save_track_level(text, integer, integer, text) to authenticated;

-- Remove the highest level of a track (never level 1).
create or replace function public.admin_delete_track_level(p_track text, p_level integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.staff_cap_on('manage_levels') then
    raise exception 'Only a Master or Super Admin can edit levels';
  end if;
  if p_level <= 1 then raise exception 'Level 1 cannot be removed'; end if;
  if p_level <> (select max(level) from public.track_levels where track = p_track) then
    raise exception 'Only the highest level can be removed';
  end if;
  delete from public.track_levels where track = p_track and level = p_level;
  perform public.recompute_track_levels(p_track);
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'levels.removed', p_track || ' level ' || p_level, 'warning');
end;
$$;
revoke execute on function public.admin_delete_track_level(text, integer) from public, anon;
grant execute on function public.admin_delete_track_level(text, integer) to authenticated;

-- gifts feed the tracks from the panel-managed table now
create or replace function public.award_wealth_charm_xp()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update public.profiles set
    wealth_xp = wealth_xp + new.coins,
    wealth_level = coalesce((
      select max(level) from public.track_levels
      where track = 'wealth' and xp_required <= profiles.wealth_xp + new.coins
    ), 1)
  where id = new.sender_id;

  update public.profiles set
    charm_xp = charm_xp + new.coins,
    charm_level = coalesce((
      select max(level) from public.track_levels
      where track = 'charm' and xp_required <= profiles.charm_xp + new.coins
    ), 1)
  where id = new.receiver_id;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- The join row carries the level image (alongside any entry effect / vehicle)
-- ---------------------------------------------------------------------------
alter table public.live_chat_messages add column if not exists level_image_url text;

create or replace function public.join_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_entry uuid[];
  v_level_image text;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in to join a live stream';
  end if;

  if public.is_ghost(auth.uid()) then
    -- no viewer row (so not listed, not counted), no "joined" line, no entry effect
    insert into public.ghost_watch_log (watcher_id, via, live_stream_id, host_id)
    select auth.uid(), 'app', s.id, s.host_id from public.live_streams s where s.id = p_stream_id;
    update public.ghost_accounts set last_watched_at = now() where profile_id = auth.uid();
    return;
  end if;

  update public.live_stream_viewers
  set left_at = now()
  where live_stream_id = p_stream_id and viewer_id = auth.uid() and left_at is null;
  insert into public.live_stream_viewers (live_stream_id, viewer_id)
  values (p_stream_id, auth.uid());

  select array_agg(ui.item_id order by case si.category when 'vehicle' then 0 else 1 end)
    into v_entry
    from public.user_items ui
    join public.store_items si on si.id = ui.item_id
   where ui.profile_id = auth.uid()
     and ui.equipped
     and ui.expires_at > now()
     and si.status = 'active'
     and si.category in ('entry_effect', 'vehicle');

  -- the highest level image the user has reached, in either track (wealth wins a tie)
  select tl.image_url into v_level_image
    from public.track_levels tl
    join public.profiles p on p.id = auth.uid()
   where tl.image_url is not null
     and tl.level <= case tl.track when 'wealth' then p.wealth_level else p.charm_level end
   order by tl.level desc, case tl.track when 'wealth' then 0 else 1 end
   limit 1;

  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, entry_item_ids, level_image_url)
  values (p_stream_id, auth.uid(), 'joined the live stream', 'system', v_entry, v_level_image);
end;
$$;
