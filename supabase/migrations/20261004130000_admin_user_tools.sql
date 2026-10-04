-- Master / Super Admin tools on a user's detail page:
--   * assign a Store item (entry effect, vehicle, frame, room skin) straight into the
--     user's Bag, with a chosen duration, no coins charged
--   * edit a user's profile (name, username, bio, location, gender, birthday, photo)

create or replace function public.admin_assign_store_item(
  p_user uuid, p_item uuid, p_days integer default null, p_equip boolean default false
) returns void
language plpgsql security definer set search_path = public
as $$
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
$$;
revoke execute on function public.admin_assign_store_item(uuid, uuid, integer, boolean) from public, anon;
grant execute on function public.admin_assign_store_item(uuid, uuid, integer, boolean) to authenticated;

-- Take an assigned / owned item away again.
create or replace function public.admin_remove_user_item(p_user_item uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can remove items';
  end if;
  perform public.require_capability('manage_users');
  delete from public.user_items where id = p_user_item;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.item_removed', p_user_item::text, 'warning');
end;
$$;
revoke execute on function public.admin_remove_user_item(uuid) from public, anon;
grant execute on function public.admin_remove_user_item(uuid) to authenticated;

-- Edit an ordinary user's profile. Runs as the caller so protect_username lets a
-- staff change of the username through. Staff accounts have their own editor.
create or replace function public.admin_update_user_profile(
  p_user_id uuid,
  p_name text,
  p_username text,
  p_bio text default null,
  p_location text default null,
  p_gender text default null,
  p_date_of_birth date default null,
  p_avatar_url text default null,
  p_phone text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_username text := nullif(trim(coalesce(p_username, '')), '');
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can edit a user';
  end if;
  perform public.require_capability('manage_users');
  if exists (select 1 from public.staff_roles where user_id = p_user_id) then
    raise exception 'Staff accounts are edited from Admin Management';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'That user does not exist';
  end if;
  if v_name is null then raise exception 'Name is required'; end if;
  if v_username is null or v_username !~ '^[a-zA-Z0-9_]{3,30}$' then
    raise exception 'Username must be 3-30 characters: letters, numbers, underscore';
  end if;
  if p_gender is not null and p_gender <> '' and p_gender not in ('female', 'male', 'other') then
    raise exception 'Gender must be female, male or other';
  end if;
  if exists (select 1 from public.profiles where lower(username) = lower(v_username) and id <> p_user_id) then
    raise exception 'That username is already taken';
  end if;

  update public.profiles set
    name = v_name,
    username = v_username,
    bio = coalesce(p_bio, bio),
    location = coalesce(nullif(trim(coalesce(p_location, '')), ''), location),
    gender = case when p_gender is null then gender when p_gender = '' then null else p_gender end,
    date_of_birth = coalesce(p_date_of_birth, date_of_birth),
    phone = case when p_phone is null then phone else nullif(trim(p_phone), '') end,
    avatar_url = coalesce(nullif(trim(coalesce(p_avatar_url, '')), ''), avatar_url)
  where id = p_user_id;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.profile_updated', p_user_id::text, 'info');
end;
$$;
revoke execute on function public.admin_update_user_profile(uuid, text, text, text, text, text, date, text, text) from public, anon;
grant execute on function public.admin_update_user_profile(uuid, text, text, text, text, text, date, text, text) to authenticated;

-- Avatars: a Master / Super Admin may upload a photo into an ordinary user's folder
-- (a staff folder is already covered by can_manage_avatar_folder).
create or replace function public.can_admin_upload_user_avatar(p_folder text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.is_admin_or_above(), false)
     and p_folder ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
$$;
revoke execute on function public.can_admin_upload_user_avatar(text) from public, anon;
grant execute on function public.can_admin_upload_user_avatar(text) to authenticated;

create policy "Admins can upload avatars for any user"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and public.can_admin_upload_user_avatar((storage.foldername(name))[1]));
create policy "Admins can replace avatars for any user"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and public.can_admin_upload_user_avatar((storage.foldername(name))[1]));
