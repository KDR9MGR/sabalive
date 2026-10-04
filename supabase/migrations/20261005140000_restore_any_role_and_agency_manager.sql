-- Lift-revoke, part 2.
-- 1) A Super Admin or a Master may lift ANY revoked staff role (a Master not a
--    Super Admin one); everyone else still follows the normal management ladder.
--    Still only back to the exact role that was revoked, and only if it was revoked.
create or replace function public.restore_staff_role(
  p_user_id uuid, p_role public.staff_role, p_agency_id uuid default null, p_country_admin_id uuid default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_role public.staff_role := public.current_staff_role();
  v_revoked_role text;
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  if p_user_id = v_actor then raise exception 'You cannot restore your own role'; end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'That user does not exist';
  end if;
  if exists (select 1 from public.staff_roles where user_id = p_user_id) then
    raise exception 'That account already has a staff role';
  end if;

  select substring(target from '\(([a-z_]+)\)\s*$') into v_revoked_role
    from public.audit_logs
   where action = 'staff.revoked' and target like p_user_id::text || ' (%'
   order by created_at desc limit 1;
  if v_revoked_role is null then raise exception 'That account has no revoked role to lift'; end if;
  if v_revoked_role <> p_role::text then
    raise exception 'That account was revoked as %, so it can only be restored as that', replace(v_revoked_role, '_', ' ');
  end if;

  if v_actor_role = 'super_admin' then
    null; -- may lift any revoke
  elsif v_actor_role = 'admin' then
    if p_role = 'super_admin' then raise exception 'Only a Super Admin can restore a Super Admin'; end if;
  elsif not public.can_manage_staff_role(v_actor_role, p_role) then
    raise exception 'You are not allowed to restore this account';
  end if;

  if p_role = 'agency_manager' then
    if p_agency_id is null then raise exception 'An agency manager needs an agency'; end if;
  elsif p_role <> 'sub_admin' and p_agency_id is not null then
    raise exception '% accounts have no agency', initcap(replace(p_role::text, '_', ' '));
  end if;
  if p_agency_id is not null and not exists (select 1 from public.agencies where id = p_agency_id) then
    raise exception 'That agency does not exist';
  end if;
  if p_role = 'sub_admin' and p_country_admin_id is not null
     and not exists (select 1 from public.staff_roles where user_id = p_country_admin_id and role = 'country_admin') then
    raise exception 'The owning account is not a country admin';
  end if;

  insert into public.staff_roles (user_id, role, agency_id, country_admin_id)
    values (p_user_id, p_role, p_agency_id, case when p_role = 'sub_admin' then p_country_admin_id end);

  if p_role = 'agency_manager' then
    update public.agencies set manager_id = p_user_id where id = p_agency_id and manager_id is null;
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (v_actor, 'staff.restored', p_user_id::text || ' (' || p_role::text || ')', 'warning');
end;
$$;
revoke execute on function public.restore_staff_role(uuid, public.staff_role, uuid, uuid) from public, anon;
grant execute on function public.restore_staff_role(uuid, public.staff_role, uuid, uuid) to authenticated;

-- 2) Lift an agency-manager revoke. revoke_agency_manager deletes the agency's manager
--    logins without recording who they were, so the person to put back is chosen:
--    they become the agency's manager, and an agency the revoke set Inactive is
--    switched back to Active. Master / Super Admin only (same as the revoke).
create or replace function public.restore_agency_manager(p_agency_id uuid, p_user_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_role public.staff_role := public.current_staff_role();
  v_name text;
  v_status text;
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  if v_actor_role is distinct from 'admin' and v_actor_role is distinct from 'super_admin' then
    raise exception 'Only a Master or Super Admin can restore an agency manager';
  end if;
  if p_user_id = v_actor then raise exception 'You cannot make yourself an agency manager here'; end if;

  select name, status into v_name, v_status from public.agencies where id = p_agency_id;
  if v_name is null then raise exception 'That agency does not exist'; end if;
  if not exists (
    select 1 from public.audit_logs
     where action = 'agency.manager_revoked' and target like '% (' || p_agency_id::text || ')'
  ) then
    raise exception 'That agency has no revoked manager to lift';
  end if;
  if exists (select 1 from public.staff_roles where role = 'agency_manager' and agency_id = p_agency_id) then
    raise exception 'That agency already has a manager login';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'That user does not exist';
  end if;
  if exists (select 1 from public.staff_roles where user_id = p_user_id) then
    raise exception 'That account already has a staff role';
  end if;

  insert into public.staff_roles (user_id, role, agency_id) values (p_user_id, 'agency_manager', p_agency_id);
  update public.agencies
     set manager_id = p_user_id,
         status = case when status = 'inactive' then 'active' else status end
   where id = p_agency_id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (v_actor, 'agency.manager_restored', v_name || ' (' || p_agency_id::text || ')', 'warning');

  return jsonb_build_object('agency', v_name, 'reactivated', v_status = 'inactive');
end;
$$;
revoke execute on function public.restore_agency_manager(uuid, uuid) from public, anon;
grant execute on function public.restore_agency_manager(uuid, uuid) to authenticated;
