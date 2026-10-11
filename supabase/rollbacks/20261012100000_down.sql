-- Down script for supabase/migrations/20261012100000_profile_assign_remove.sql
-- Applied BY HAND only. Puts the four assign/remove functions back to their manage_users gate, and drops the two new
-- functions and the three policies. Badges / frames already removed stay removed.
begin;
set local lock_timeout = '5s';
drop function if exists public.admin_remove_user_badge(uuid, uuid);
drop function if exists public.admin_remove_user_frame(uuid, uuid);
drop policy if exists "Granted view_user_profile: insert user_badges" on public.user_badges;
drop policy if exists "Granted view_user_profile: insert user_frames" on public.user_frames;
drop policy if exists "Staff delete assignments in their scope" on public.assignments;

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
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can assign items';
  end if;
  perform public.require_capability('manage_users');

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
CREATE OR REPLACE FUNCTION public.admin_remove_user_item(p_user_item uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can remove items';
  end if;
  perform public.require_capability('manage_users');
  delete from public.user_items where id = p_user_item;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.item_removed', p_user_item::text, 'warning');
end;
$function$;
CREATE OR REPLACE FUNCTION public.admin_assign_lucky_id(p_lucky uuid, p_user uuid, p_days integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_days integer;
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can assign Lucky IDs';
  end if;
  perform public.require_capability('manage_users');
  select coalesce(p_days, duration_days) into v_days from public.lucky_ids where id = p_lucky;
  if v_days is null then raise exception 'That Lucky ID does not exist'; end if;
  if v_days < 1 or v_days > 3650 then raise exception 'Days must be between 1 and 3650'; end if;
  perform public.lucky_claim(p_lucky, p_user, v_days, auth.uid());
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.lucky_id_assigned', p_user::text || ' <- ' || p_lucky::text, 'info');
end;
$function$;
CREATE OR REPLACE FUNCTION public.admin_revoke_lucky_id(p_lucky uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can revoke Lucky IDs';
  end if;
  perform public.require_capability('manage_users');
  perform public.lucky_release(p_lucky);
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.lucky_id_revoked', p_lucky::text, 'warning');
end;
$function$;
commit;
