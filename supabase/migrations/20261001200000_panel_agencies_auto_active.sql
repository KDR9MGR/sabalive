-- An agency created THROUGH THE PANEL (by a Sub Admin for itself, or by a
-- Country/Global/Master admin picking a sub admin to own it) already went
-- through a deliberate staff action — making it sit 'pending' for a SEPARATE
-- manual approval afterward is redundant friction, not a real review step.
-- That friction only ever mattered for the app's self-serve apply_for_agency
-- (20260923160000), which stays fully blocked (20261001180000) — unchanged
-- by this migration.
--
-- Also: create_country_agency never allowed 'admin' (Master) to call it —
-- only 'country_admin'/'global_admin' — the same class of gap as
-- invite-staff's CREATOR_ROLES (20261001180000's sibling fix). Master is
-- meant to manage the whole hierarchy (20261001090000); fixing it here too.
create or replace function public.create_sub_admin_agency(p_name text, p_country text default 'India')
returns public.agencies
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.agencies;
begin
  if public.current_staff_role() is distinct from 'sub_admin' then
    raise exception 'Only a sub admin can add an agency here';
  end if;
  if nullif(trim(p_name), '') is null then
    raise exception 'Agency name is required';
  end if;

  insert into public.agencies (name, country, status, sub_admin_id)
    values (trim(p_name), coalesce(nullif(trim(p_country), ''), 'India'), 'active', auth.uid())
    returning * into v_row;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'agency.create', v_row.name, 'info');

  return v_row;
end;
$$;

create or replace function public.create_country_agency(p_name text, p_sub_admin uuid, p_country text default 'India')
returns public.agencies
language plpgsql security definer set search_path = public
as $$
declare
  v_role public.staff_role := public.current_staff_role();
  v_row public.agencies;
begin
  if v_role is null or v_role not in ('country_admin', 'global_admin', 'admin') then
    raise exception 'Only a global admin, country admin or Master can add an agency here';
  end if;
  if nullif(trim(p_name), '') is null then
    raise exception 'Agency name is required';
  end if;
  if v_role = 'country_admin' and not public.owns_sub_admin(p_sub_admin) then
    raise exception 'Pick one of your own sub admins to own this agency';
  end if;
  if not exists (select 1 from public.staff_roles where user_id = p_sub_admin and role = 'sub_admin') then
    raise exception 'The owning account is not a sub admin';
  end if;

  insert into public.agencies (name, country, status, sub_admin_id)
    values (trim(p_name), coalesce(nullif(trim(p_country), ''), 'India'), 'active', p_sub_admin)
    returning * into v_row;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'agency.create', v_row.name, 'info');
  return v_row;
end;
$$;
