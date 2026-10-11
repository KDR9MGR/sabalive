-- "View user profile" now also carries the profile's assign / remove actions (Bag items, Lucky ID, badges, frames),
-- so a Master (on by default), or any account the switch is granted to, can assign AND take back what is on a profile.
--   * admin_assign_store_item, admin_remove_user_item, admin_assign_lucky_id, admin_revoke_lucky_id: the first gate becomes
--     staff_cap_on('view_user_profile') and the extra require_capability('manage_users') goes (that switch no longer governs these).
--   * NEW admin_remove_user_badge / admin_remove_user_frame (badges and frames could be assigned but never removed;
--     removing a frame row re-syncs the profile's frame through the existing user_frames trigger).
--   * user_badges / user_frames: new permissive INSERT policies for a granted account (assigning is a direct insert).
--   * NEW DELETE policy on assignments (Host Assignment could create and edit but never remove): same scope as its UPDATE.
-- Rollback: supabase/rollbacks/20261012100000_down.sql.

-- admin_assign_store_item
CREATE OR REPLACE FUNCTION public.admin_assign_store_item(p_user uuid, p_item uuid, p_days integer DEFAULT NULL::integer, p_equip boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item public.store_items%rowtype;
  v_days integer;
  v_existing public.user_items%rowtype;
  v_id uuid;
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Only a Master or Super Admin can assign items';
  end if;

  select * into v_item from public.store_items where id = p_item;
  if not found then raise exception 'That item does not exist'; end if;
  if v_item.category = 'vip' then
    raise exception 'Lucky IDs are assigned from the Lucky ID page';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'That user does not exist';
  end if;

  v_days := coalesce(p_days, v_item.duration_days);
  if v_days < 1 or v_days > 3650 then raise exception 'Days must be between 1 and 3650'; end if;

  -- an unexpired copy is extended; otherwise a fresh one starts now
  select * into v_existing from public.user_items
   where profile_id = p_user and item_id = p_item and expires_at > now()
   order by expires_at desc limit 1;
  if found then
    update public.user_items set expires_at = expires_at + make_interval(days => v_days)
     where id = v_existing.id returning id into v_id;
  else
    insert into public.user_items (profile_id, item_id, expires_at, equipped)
    values (p_user, p_item, now() + make_interval(days => v_days), false)
    returning id into v_id;
  end if;

  if p_equip then
    update public.user_items set equipped = false
     where profile_id = p_user and equipped
       and item_id in (select id from public.store_items where category = v_item.category);
    update public.user_items set equipped = true where id = v_id;
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.item_assigned', p_user::text || ' <- ' || v_item.name || ' (' || v_days || 'd)', 'info');
end;
$function$;

-- admin_remove_user_item
CREATE OR REPLACE FUNCTION public.admin_remove_user_item(p_user_item uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Only a Master or Super Admin can remove items';
  end if;
  delete from public.user_items where id = p_user_item;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.item_removed', p_user_item::text, 'warning');
end;
$function$;

-- admin_assign_lucky_id
CREATE OR REPLACE FUNCTION public.admin_assign_lucky_id(p_lucky uuid, p_user uuid, p_days integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_days integer;
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Only a Master or Super Admin can assign Lucky IDs';
  end if;
  select coalesce(p_days, duration_days) into v_days from public.lucky_ids where id = p_lucky;
  if v_days is null then raise exception 'That Lucky ID does not exist'; end if;
  if v_days < 1 or v_days > 3650 then raise exception 'Days must be between 1 and 3650'; end if;
  perform public.lucky_claim(p_lucky, p_user, v_days, auth.uid());
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.lucky_id_assigned', p_user::text || ' <- ' || p_lucky::text, 'info');
end;
$function$;

-- admin_revoke_lucky_id
CREATE OR REPLACE FUNCTION public.admin_revoke_lucky_id(p_lucky uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Only a Master or Super Admin can revoke Lucky IDs';
  end if;
  perform public.lucky_release(p_lucky);
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.lucky_id_revoked', p_lucky::text, 'warning');
end;
$function$;

-- remove a badge from a user
create or replace function public.admin_remove_user_badge(p_profile uuid, p_badge uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Not allowed to change a user''s badges';
  end if;
  delete from public.user_badges where profile_id = p_profile and badge_id = p_badge;
  if not found then raise exception 'That user does not have that badge'; end if;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.badge_removed', p_profile::text || ' -> ' || p_badge::text, 'info');
end;
$$;
revoke execute on function public.admin_remove_user_badge(uuid, uuid) from public, anon;
grant execute on function public.admin_remove_user_badge(uuid, uuid) to authenticated;

-- remove a profile frame from a user (the user_frames trigger re-computes profiles.frame_url)
create or replace function public.admin_remove_user_frame(p_profile uuid, p_frame uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Not allowed to change a user''s frames';
  end if;
  delete from public.user_frames where profile_id = p_profile and frame_id = p_frame;
  if not found then raise exception 'That user does not have that frame'; end if;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.frame_removed', p_profile::text || ' -> ' || p_frame::text, 'info');
end;
$$;
revoke execute on function public.admin_remove_user_frame(uuid, uuid) from public, anon;
grant execute on function public.admin_remove_user_frame(uuid, uuid) to authenticated;

-- assigning a badge / frame is a direct insert: open it to an account the switch was granted to
drop policy if exists "Granted view_user_profile: insert user_badges" on public.user_badges;
create policy "Granted view_user_profile: insert user_badges" on public.user_badges for insert
  with check ((select public.staff_can('view_user_profile')));
drop policy if exists "Granted view_user_profile: insert user_frames" on public.user_frames;
create policy "Granted view_user_profile: insert user_frames" on public.user_frames for insert
  with check ((select public.staff_can('view_user_profile')));

-- Host Assignment: a staff member could create and edit an assignment but never remove it
drop policy if exists "Staff delete assignments in their scope" on public.assignments;
create policy "Staff delete assignments in their scope" on public.assignments for delete
  using (is_admin_or_above() OR (EXISTS ( SELECT 1 FROM host_profiles hp WHERE ((hp.profile_id = assignments.host_id) AND manages_agency(hp.agency_id)))));
