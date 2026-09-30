-- Master (role 'admin') sits above Global Admin and was never added to the
-- hierarchy creation rules from 20260930170000 — until now an 'admin' actor
-- hit the final `else` in check_staff_creation and could not create a
-- Global Admin, Country Admin, Sub Admin or Agency account at all, despite
-- is_global_scope() (20260930160000) already treating 'admin' as seeing the
-- whole tree for reads. This closes that gap for writes too: Master may
-- create anything below it, same ceiling as Global Admin one level down,
-- and any agency is in a Master's scope (mirrors the 'global_admin' branch
-- in both places below). Re-emitting both function bodies verbatim (from
-- 20260930170000_hierarchy_account_creation.sql) with the one added branch
-- each, nothing else changes.
create or replace function public.check_staff_creation(
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
  elsif v_actor = 'admin' and p_role in ('global_admin', 'country_admin', 'sub_admin', 'agency_manager') then
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
      when 'admin'         then true
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
