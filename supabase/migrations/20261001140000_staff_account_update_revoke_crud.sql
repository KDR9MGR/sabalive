-- CRUD completion: Master (and, by the same rule, Global/Country/Sub Admin)
-- could already Create and Read staff accounts in its tree, but Update
-- (change role) and Revoke were still locked to the direct staff_roles RLS
-- path, which only super_admin ever passed — so a Master literally could
-- not edit or remove anyone it had just created. Two new RPCs, mirroring
-- check_staff_creation's hierarchy rule but as a reusable predicate so
-- update/revoke don't have to duplicate its shape/scope checks wholesale.
create function public.can_manage_staff_role(p_actor_role public.staff_role, p_target_role public.staff_role)
returns boolean language sql immutable set search_path = public
as $$
  select case p_actor_role
    when 'admin'         then p_target_role in ('global_admin', 'country_admin', 'sub_admin', 'agency_manager')
    when 'global_admin'  then p_target_role in ('country_admin', 'sub_admin', 'agency_manager')
    when 'country_admin' then p_target_role in ('sub_admin', 'agency_manager')
    when 'sub_admin'     then p_target_role = 'agency_manager'
    else false
  end;
$$;

-- Correction: this trigger (added in 20261001100000) assumed every update
-- that reaches it comes from a super_admin, because at the time the only
-- way to UPDATE staff_roles was the RLS-gated direct path, which only
-- super_admin ever passes. update_staff_role below is a SECURITY DEFINER
-- RPC that bypasses that RLS by design, so the trigger must actually check
-- who's acting instead of assuming — otherwise it would wrongly block
-- Master (or any level) from setting a role to anything but 'admin'.
create or replace function public.restrict_super_admin_role_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.current_staff_role() = 'super_admin'
     and new.role is distinct from old.role and new.role <> 'admin' then
    raise exception 'A Super Admin may only change a role to Master (admin)';
  end if;
  return new;
end;
$$;

create function public.update_staff_role(
  p_user_id uuid, p_role public.staff_role, p_agency_id uuid default null, p_country_admin_id uuid default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_role public.staff_role := public.current_staff_role();
  v_current public.staff_role;
  v_owner uuid;
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  if p_user_id = v_actor then raise exception 'You cannot change your own role'; end if;

  select role into v_current from public.staff_roles where user_id = p_user_id;
  if v_current is null then raise exception 'That account has no staff role'; end if;

  if v_actor_role = 'super_admin' then
    if v_current <> 'admin' or p_role <> 'admin' then
      raise exception 'A Super Admin may only manage Master accounts';
    end if;
  else
    if not public.can_manage_staff_role(v_actor_role, v_current) then
      raise exception 'You are not allowed to manage this account';
    end if;
    if not public.can_manage_staff_role(v_actor_role, p_role) then
      raise exception 'Your role cannot assign % accounts', replace(p_role::text, '_', ' ');
    end if;
  end if;

  if p_role = 'agency_manager' then
    if p_agency_id is null then raise exception 'An agency manager needs an agency'; end if;
  elsif p_role <> 'sub_admin' and p_agency_id is not null then
    raise exception '% accounts have no agency', initcap(replace(p_role::text, '_', ' '));
  end if;

  if p_agency_id is not null then
    if not exists (select 1 from public.agencies where id = p_agency_id) then
      raise exception 'That agency does not exist';
    end if;
  end if;
  if p_role = 'sub_admin' and p_country_admin_id is not null
     and not exists (select 1 from public.staff_roles where user_id = p_country_admin_id and role = 'country_admin') then
    raise exception 'The owning account is not a country admin';
  end if;

  v_owner := case when p_role = 'sub_admin' then p_country_admin_id end;
  update public.staff_roles
    set role = p_role, agency_id = p_agency_id, country_admin_id = v_owner
    where user_id = p_user_id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (v_actor, 'staff.role_changed', p_user_id::text || ' -> ' || p_role::text, 'warning');
end;
$$;

grant execute on function public.update_staff_role(uuid, public.staff_role, uuid, uuid) to authenticated;

create function public.revoke_staff_role(p_user_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_role public.staff_role := public.current_staff_role();
  v_current public.staff_role;
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  if p_user_id = v_actor then raise exception 'You cannot revoke your own role'; end if;

  select role into v_current from public.staff_roles where user_id = p_user_id;
  if v_current is null then raise exception 'That account has no staff role'; end if;

  if v_current = 'super_admin' then
    if v_actor_role <> 'super_admin' then raise exception 'Only a Super Admin can revoke a Super Admin'; end if;
    if (select count(*) from public.staff_roles where role = 'super_admin') <= 1 then
      raise exception 'Cannot revoke the last Super Admin';
    end if;
  elsif v_actor_role = 'super_admin' then
    null; -- a Super Admin may revoke anyone else as a safety backstop (20261001100000)
  elsif not public.can_manage_staff_role(v_actor_role, v_current) then
    raise exception 'You are not allowed to revoke this account';
  end if;

  delete from public.staff_roles where user_id = p_user_id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (v_actor, 'staff.revoked', p_user_id::text || ' (' || v_current::text || ')', 'warning');
end;
$$;

grant execute on function public.revoke_staff_role(uuid) to authenticated;
