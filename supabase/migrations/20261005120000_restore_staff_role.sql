-- "Lift revoke": put a revoked staff account straight back. It restores exactly the
-- role that was revoked (read from the audit log written by revoke_staff_role), by
-- someone who is allowed to manage that role — a Super Admin only Master, Master
-- anything below, and so on — so it can't be used to grant a role that wasn't taken.
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

  -- only a role that was actually revoked can be lifted, and only back to the same role
  select substring(target from '\(([a-z_]+)\)\s*$') into v_revoked_role
    from public.audit_logs
   where action = 'staff.revoked' and target like p_user_id::text || ' (%'
   order by created_at desc limit 1;
  if v_revoked_role is null then raise exception 'That account has no revoked role to lift'; end if;
  if v_revoked_role <> p_role::text then
    raise exception 'That account was revoked as %, so it can only be restored as that', replace(v_revoked_role, '_', ' ');
  end if;

  if v_actor_role = 'super_admin' then
    if p_role <> 'admin' then raise exception 'A Super Admin may only restore Master accounts'; end if;
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

  -- an agency's login is its manager of record again
  if p_role = 'agency_manager' then
    update public.agencies set manager_id = p_user_id where id = p_agency_id and manager_id is null;
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (v_actor, 'staff.restored', p_user_id::text || ' (' || p_role::text || ')', 'warning');
end;
$$;
revoke execute on function public.restore_staff_role(uuid, public.staff_role, uuid, uuid) from public, anon;
grant execute on function public.restore_staff_role(uuid, public.staff_role, uuid, uuid) to authenticated;
