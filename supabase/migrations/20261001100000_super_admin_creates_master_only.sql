-- Super Admin's account-creation power narrows to Master (role 'admin')
-- only — not another Super Admin, not Global Admin, not Country Admin, not
-- Sub Admin, not Agency Manager. Master already cascades everything below
-- it (20261001090000), so the intended chain is now strictly
-- Super Admin -> Master -> Global Admin -> Country Admin -> Sub Admin -> Agency.
-- Revoking a role (any level) is left alone — that's a safety backstop, not
-- account creation, and Super Admin should still be able to pull the plug
-- on a compromised account anywhere in the tree.

-- ---------------------------------------------------------- new-login path
-- (invite-staff edge function -> create_staff_account -> this). Re-emitting
-- the body verbatim from 20261001090000 with the one changed condition.
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
  if v_actor = 'super_admin' and p_role = 'admin' then
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

-- ---------------------------------------------------------- direct-grant path
-- ("Grant Role" on an already-signed-up user — only ever reachable by a
-- super_admin in the first place, both policies are already gated that way).
drop policy "Only super admins assign roles" on public.staff_roles;
create policy "Only super admins assign roles"
  on public.staff_roles for insert with check (public.is_super_admin() and role = 'admin');

-- The UPDATE policy stays broad (a permissions-jsonb edit on a Global Admin's
-- row must keep working) — a trigger below blocks only an actual ROLE change
-- to anything but 'admin', leaving every other column free to update.
create function public.restrict_super_admin_role_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and new.role <> 'admin' then
    raise exception 'A Super Admin may only change a role to Master (admin)';
  end if;
  return new;
end;
$$;

create trigger restrict_super_admin_role_changes_trigger
  before update on public.staff_roles
  for each row execute function public.restrict_super_admin_role_changes();
