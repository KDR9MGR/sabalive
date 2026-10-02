-- Master (role 'admin') can edit the PROFILE of the staff accounts directly
-- below it (global_admin, country_admin, sub_admin, agency_manager), and
-- revoke an agency's manager. Until now nobody could write another account's
-- profile at all: profiles only has a "users update their own row" policy,
-- phone has no UPDATE grant, and no admin RPC existed.
--
-- These new capabilities are deliberately Master-only server-side (not the
-- wider role ladder revoke_staff_role/update_staff_role use) — the panel only
-- exposes them to Master, and anything wider would let a Sub Admin call them
-- straight against the API for accounts outside its tree.

-- Single source of the "may this caller manage that account" rule, shared by
-- the profile RPC, the avatar storage policy and the admin-update-staff-auth
-- Edge Function (which calls it with the service role and an explicit actor).
create or replace function public.assert_can_manage_staff(p_actor uuid, p_target uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_actor_role public.staff_role;
  v_target_role public.staff_role;
begin
  if p_actor is null then raise exception 'Sign in first'; end if;
  if p_actor = p_target then raise exception 'You cannot edit your own account here'; end if;

  select role into v_actor_role from public.staff_roles where user_id = p_actor;
  if v_actor_role is distinct from 'admin' then
    raise exception 'Only a Master can edit staff accounts';
  end if;

  select role into v_target_role from public.staff_roles where user_id = p_target;
  if v_target_role is null then raise exception 'That account has no staff role'; end if;
  if not public.can_manage_staff_role(v_actor_role, v_target_role) then
    raise exception 'You are not allowed to manage this account';
  end if;
end;
$$;

revoke execute on function public.assert_can_manage_staff(uuid, uuid) from public, anon, authenticated;
grant execute on function public.assert_can_manage_staff(uuid, uuid) to service_role;

create or replace function public.admin_update_staff_profile(
  p_user_id uuid,
  p_name text,
  p_username text,
  p_phone text,
  p_location text,
  p_bio text default null,
  p_avatar_url text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_location text := nullif(trim(coalesce(p_location, '')), '');
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  perform public.assert_can_manage_staff(v_actor, p_user_id);

  if v_name is null then raise exception 'Name is required'; end if;
  if v_username is null or v_username !~ '^[a-zA-Z0-9_]{3,30}$' then
    raise exception 'Username must be 3-30 characters: letters, numbers, underscore';
  end if;
  if v_location is null then raise exception 'Location is required'; end if;
  if exists (
    select 1 from public.profiles
    where lower(username) = lower(v_username) and id <> p_user_id
  ) then
    raise exception 'That username is already taken';
  end if;

  -- Runs as the Master (auth.uid() is still the caller), so the
  -- protect_username trigger's is_staff() check lets the username change
  -- through — a service-role write would silently get it reverted.
  update public.profiles set
    name = v_name,
    username = v_username,
    location = v_location,
    phone = nullif(trim(coalesce(p_phone, '')), ''),
    bio = coalesce(p_bio, bio),
    avatar_url = coalesce(nullif(trim(coalesce(p_avatar_url, '')), ''), avatar_url)
  where id = p_user_id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (v_actor, 'staff.profile_updated', p_user_id::text, 'info');
end;
$$;

revoke execute on function public.admin_update_staff_profile(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.admin_update_staff_profile(uuid, text, text, text, text, text, text) to authenticated;

-- Revoke an agency's manager login AND take the agency out of service, in one
-- transaction so a half-applied revoke can't leave an active agency with no
-- manager (or an inactive one that still has a login).
create or replace function public.revoke_agency_manager(p_agency_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_name text;
  v_revoked integer;
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  if public.current_staff_role() is distinct from 'admin' then
    raise exception 'Only a Master can revoke an agency manager';
  end if;

  select name into v_name from public.agencies where id = p_agency_id;
  if v_name is null then raise exception 'That agency does not exist'; end if;

  with gone as (
    delete from public.staff_roles
    where role = 'agency_manager' and agency_id = p_agency_id
    returning user_id
  )
  select count(*) into v_revoked from gone;

  update public.agencies set status = 'inactive', manager_id = null where id = p_agency_id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (v_actor, 'agency.manager_revoked', v_name || ' (' || p_agency_id::text || ')', 'warning');

  return jsonb_build_object('revoked', v_revoked);
end;
$$;

revoke execute on function public.revoke_agency_manager(uuid) from public, anon;
grant execute on function public.revoke_agency_manager(uuid) to authenticated;

-- Avatars: a Master may upload a photo into a managed account's folder
-- ('<target uid>/...'), which today only the owner can write.
create or replace function public.can_manage_avatar_folder(p_folder text)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
begin
  if p_folder is null or p_folder !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return false;
  end if;
  perform public.assert_can_manage_staff(auth.uid(), p_folder::uuid);
  return true;
exception when others then
  return false;
end;
$$;

create policy "Master can upload avatars for accounts it manages"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and public.can_manage_avatar_folder((storage.foldername(name))[1])
  );
