-- Hierarchy stage 4: every level creates the level below it.
--
--   super_admin   -> any role
--   global_admin  -> country_admin, sub_admin, agency_manager
--   country_admin -> sub_admin (owned by them), agency_manager (in their tree)
--   sub_admin     -> agency_manager (for an agency they own)
--
-- Until now only a Super Admin could create a login (invite-staff edge function
-- + "Only super admins assign roles" RLS on staff_roles). Creating a login needs
-- the service role, so the edge function stays the only entry point — but it now
-- asks THESE functions who may create what, so the rules live in SQL (where they
-- are tested) instead of being duplicated in TypeScript.
--
-- Both functions take the caller explicitly (p_actor) and are executable ONLY by
-- service_role: a signed-in user cannot call them directly, so nobody can use
-- them to hand a role to an arbitrary existing account.
-- The staff_roles RLS policies are unchanged — direct inserts stay Super-only.

create function public.check_staff_creation(
  p_actor uuid,
  p_role public.staff_role,
  p_agency_id uuid,
  p_country_admin_id uuid
) returns void
language plpgsql stable security definer set search_path = public
as $$
declare
  v_actor public.staff_role;
  v_agency_owner uuid;
  v_in_scope boolean := false;
begin
  select role into v_actor from public.staff_roles where user_id = p_actor;
  if v_actor is null then
    raise exception 'Only staff can create accounts';
  end if;

  -- 1. may this level create this role at all?
  if v_actor = 'super_admin' then
    null;
  elsif v_actor = 'global_admin' and p_role in ('country_admin', 'sub_admin', 'agency_manager') then
    null;
  elsif v_actor = 'country_admin' and p_role in ('sub_admin', 'agency_manager') then
    null;
  elsif v_actor = 'sub_admin' and p_role = 'agency_manager' then
    null;
  else
    raise exception 'Your role (%) cannot create % accounts', replace(v_actor::text, '_', ' '), replace(p_role::text, '_', ' ');
  end if;

  -- 2. role-specific shape
  if p_role = 'agency_manager' then
    if p_agency_id is null then raise exception 'An agency manager needs an agency'; end if;
    if p_country_admin_id is not null then raise exception 'country_admin_id only applies to a sub admin'; end if;
  elsif p_role = 'sub_admin' then
    null;
  else
    if p_agency_id is not null then raise exception '% accounts have no agency', initcap(replace(p_role::text, '_', ' ')); end if;
    if p_country_admin_id is not null then raise exception 'country_admin_id only applies to a sub admin'; end if;
  end if;

  -- 3. the agency (if any) must be inside the actor's scope
  if p_agency_id is not null then
    select sub_admin_id into v_agency_owner from public.agencies where id = p_agency_id;
    if not found then raise exception 'That agency does not exist'; end if;

    v_in_scope := case v_actor
      when 'super_admin'   then true
      when 'global_admin'  then true
      when 'country_admin' then exists (
        select 1 from public.staff_roles s
         where s.user_id = v_agency_owner and s.role = 'sub_admin' and s.country_admin_id = p_actor)
      when 'sub_admin'     then v_agency_owner = p_actor
      else false end;
    if not coalesce(v_in_scope, false) then
      raise exception 'That agency is not in your scope';
    end if;
  end if;

  -- 4. owning country admin (sub admins only)
  if p_role = 'sub_admin' and p_country_admin_id is not null then
    if not exists (select 1 from public.staff_roles where user_id = p_country_admin_id and role = 'country_admin') then
      raise exception 'The owning account is not a country admin';
    end if;
    if v_actor = 'country_admin' and p_country_admin_id <> p_actor then
      raise exception 'A country admin can only create sub admins for themselves';
    end if;
  end if;
end;
$$;

create function public.create_staff_account(
  p_actor uuid,
  p_user_id uuid,
  p_role public.staff_role,
  p_agency_id uuid,
  p_country_admin_id uuid,
  p_payment_pin_hash text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_actor public.staff_role;
  v_owner uuid := p_country_admin_id;
begin
  perform public.check_staff_creation(p_actor, p_role, p_agency_id, p_country_admin_id);
  select role into v_actor from public.staff_roles where user_id = p_actor;

  -- a country admin's sub admins belong to them, whatever was passed
  if p_role = 'sub_admin' and v_actor = 'country_admin' then
    v_owner := p_actor;
  end if;

  insert into public.staff_roles (user_id, role, agency_id, country_admin_id, payment_pin_hash)
    values (p_user_id, p_role, p_agency_id, case when p_role = 'sub_admin' then v_owner end, p_payment_pin_hash);

  -- the agency's login becomes its manager of record
  if p_role = 'agency_manager' then
    update public.agencies set manager_id = p_user_id where id = p_agency_id and manager_id is null;
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (p_actor, 'staff.created', p_user_id::text || ' -> ' || p_role::text, 'warning');
end;
$$;

revoke execute on function public.check_staff_creation(uuid, public.staff_role, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.check_staff_creation(uuid, public.staff_role, uuid, uuid) to service_role;
revoke execute on function public.create_staff_account(uuid, uuid, public.staff_role, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.create_staff_account(uuid, uuid, public.staff_role, uuid, uuid, text) to service_role;
