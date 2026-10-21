-- Profile tags: short labels that STAFF give to users from the panel ("Tags") and that show on the user's profile in the app. A tag has one of
-- three looks: a coloured PILL (name on a colour), a PICTURE (a banner image with the name inside it, shown as it is) or a PLATE (a background
-- image with the name written on it by the app). A picture / plate must be a file in this project's public storage. They are separate from the Store's VIP tags (those are bought and expire); a staff tag is handed out by hand and stays until it is taken off.
--
--   profile_tags                  the catalogue (name, colour, emoji, active / inactive, order)
--   profile_tag_assignments       which user has which tag
--   staff_can_manage_tags()       Super Admin always; a Master unless an explicit false blocks; any other staff account only with an explicit true
--                                 in its permissions ("Tags" in Access Control). It is a NEW helper: staff_can() is not touched.
--   admin_save_profile_tag        create / edit a tag
--   admin_delete_profile_tag      delete a tag (it comes off everyone who had it)
--   admin_set_user_tags           set the exact tags a user has
--   set_staff_permissions         the same function as before with one more key accepted: 'manage_tags'
--
-- Reads: an active tag, and the tags assigned to anybody the caller is allowed to see (the profiles rules hide ghosts), are readable by signed-in users;
-- inactive tags only by tag managers. Writes go ONLY through the three admin_* functions (no insert / update / delete policy exists).
-- Additive only: new tables and new function names; old apps never read any of it. Rollback: supabase/rollbacks/20261021190000_down.sql.
set local lock_timeout = '5s';

create table public.profile_tags (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 24),
  color text not null default '#7c3aed' check (color ~ '^#[0-9a-f]{6}$'),
  emoji text check (emoji is null or char_length(emoji) between 1 and 12),
  look text not null default 'pill' check (look in ('pill', 'picture', 'plate')),
  image_url text check (image_url is null or (char_length(image_url) <= 600 and image_url ~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/')),
  text_color text check (text_color is null or text_color ~ '^#[0-9a-f]{6}$'),
  status text not null default 'active' check (status in ('active', 'inactive')),
  sort_order integer not null default 0,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint profile_tags_picture_needs_image check (look = 'pill' or image_url is not null)
);
create unique index profile_tags_name_unique on public.profile_tags (lower(btrim(name)));

create table public.profile_tag_assignments (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  tag_id uuid not null references public.profile_tags (id) on delete cascade,
  assigned_by uuid,
  assigned_at timestamptz not null default now(),
  primary key (profile_id, tag_id)
);
create index profile_tag_assignments_tag_idx on public.profile_tag_assignments (tag_id);

-- ------------------------------------------------------------------------------------------------------------ who may manage tags
create or replace function public.staff_can_manage_tags()
returns boolean
language sql stable security definer set search_path = public
as $$
  select case public.current_staff_role()
    when 'super_admin' then true
    when 'admin' then coalesce(
      (select nullif(s.permissions ->> 'manage_tags', '')::boolean from public.staff_roles s where s.user_id = auth.uid()), true)
    else coalesce(
      (select nullif(s.permissions ->> 'manage_tags', '')::boolean from public.staff_roles s where s.user_id = auth.uid()), false)
  end;
$$;
revoke execute on function public.staff_can_manage_tags() from public, anon;
grant execute on function public.staff_can_manage_tags() to authenticated;

-- ------------------------------------------------------------------------------------------------------------ reads (RLS)
alter table public.profile_tags enable row level security;
alter table public.profile_tag_assignments enable row level security;
revoke all on public.profile_tags, public.profile_tag_assignments from anon;
revoke insert, update, delete, truncate on public.profile_tags, public.profile_tag_assignments from authenticated;

create policy "Active tags are readable" on public.profile_tags for select to authenticated
  using (status = 'active' or (select public.staff_can_manage_tags()));
-- the profiles policy hides ghost rows, so a ghost's tags (if it ever had any) are hidden with it
create policy "Assigned tags are readable" on public.profile_tag_assignments for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = profile_id));

-- ------------------------------------------------------------------------------------------------------------ writes (functions only)
create or replace function public.admin_save_profile_tag(
  p_id uuid, p_name text, p_color text, p_emoji text, p_status text, p_sort integer,
  p_look text default 'pill', p_image_url text default null, p_text_color text default null)
returns public.profile_tags
language plpgsql security definer set search_path = public
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_color text := lower(btrim(coalesce(p_color, '')));
  v_emoji text := nullif(btrim(coalesce(p_emoji, '')), '');
  v_look text := coalesce(p_look, 'pill');
  v_image text := nullif(btrim(coalesce(p_image_url, '')), '');
  v_text_color text := nullif(lower(btrim(coalesce(p_text_color, ''))), '');
  v_row public.profile_tags;
begin
  if not public.staff_can_manage_tags() then
    raise exception 'Only a Master or Super Admin, or an account given Tags access, can manage tags';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 24 then raise exception 'A tag name is 1 to 24 characters'; end if;
  if v_color !~ '^#[0-9a-f]{6}$' then raise exception 'Pick a colour like #7c3aed'; end if;
  if v_emoji is not null and char_length(v_emoji) > 12 then raise exception 'The emoji is too long'; end if;
  if p_status is null or p_status not in ('active', 'inactive') then raise exception 'Status must be active or inactive'; end if;
  if v_look not in ('pill', 'picture', 'plate') then raise exception 'The look must be pill, picture or plate'; end if;
  if v_look = 'pill' then v_image := null; end if;
  if v_look <> 'pill' and v_image is null then raise exception 'Upload a picture for this look'; end if;
  if v_image is not null and (char_length(v_image) > 600 or v_image !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/') then
    raise exception 'The picture must be a file uploaded from the panel';
  end if;
  if v_text_color is not null and v_text_color !~ '^#[0-9a-f]{6}$' then raise exception 'The text colour must look like #ffffff'; end if;

  if p_id is null then
    insert into public.profile_tags (name, color, emoji, status, sort_order, look, image_url, text_color, created_by)
      values (v_name, v_color, v_emoji, p_status, coalesce(p_sort, 0), v_look, v_image, v_text_color, auth.uid())
      returning * into v_row;
  else
    update public.profile_tags
       set name = v_name, color = v_color, emoji = v_emoji, status = p_status, sort_order = coalesce(p_sort, 0),
           look = v_look, image_url = v_image, text_color = v_text_color
     where id = p_id
     returning * into v_row;
    if not found then raise exception 'That tag no longer exists'; end if;
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), case when p_id is null then 'profile_tag.create' else 'profile_tag.update' end,
            v_row.id::text || ' ' || v_row.name, 'info');
  return v_row;
exception when unique_violation then
  raise exception 'There is already a tag called %', v_name;
end;
$$;
revoke execute on function public.admin_save_profile_tag(uuid, text, text, text, text, integer, text, text, text) from public, anon;
grant execute on function public.admin_save_profile_tag(uuid, text, text, text, text, integer, text, text, text) to authenticated;

create or replace function public.admin_delete_profile_tag(p_id uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_name text;
  v_users integer;
begin
  if not public.staff_can_manage_tags() then
    raise exception 'Only a Master or Super Admin, or an account given Tags access, can manage tags';
  end if;
  select name into v_name from public.profile_tags where id = p_id for update;
  if v_name is null then raise exception 'That tag no longer exists'; end if;
  select count(*)::int into v_users from public.profile_tag_assignments where tag_id = p_id;
  delete from public.profile_tags where id = p_id;
  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'profile_tag.delete', p_id::text || ' ' || v_name || ' (' || v_users || ' users)', 'warning');
  return v_users;
end;
$$;
revoke execute on function public.admin_delete_profile_tag(uuid) from public, anon;
grant execute on function public.admin_delete_profile_tag(uuid) to authenticated;

create or replace function public.admin_set_user_tags(p_user uuid, p_tag_ids uuid[])
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_ids uuid[] := coalesce((select array_agg(distinct x) from unnest(p_tag_ids) x), '{}');
  v_ghost boolean;
  v_added integer;
  v_removed integer;
begin
  if not public.staff_can_manage_tags() then
    raise exception 'Only a Master or Super Admin, or an account given Tags access, can manage tags';
  end if;
  select is_ghost into v_ghost from public.profiles where id = p_user;
  if not found then raise exception 'That user does not exist'; end if;
  if v_ghost then raise exception 'Ghost accounts cannot be tagged'; end if;
  if cardinality(v_ids) > 10 then raise exception 'A user can have at most 10 tags'; end if;
  if exists (select 1 from unnest(v_ids) x where not exists (select 1 from public.profile_tags t where t.id = x)) then
    raise exception 'One of the tags no longer exists';
  end if;
  -- an inactive tag can stay on someone who already has it, but cannot be handed out
  if exists (
    select 1 from public.profile_tags t
     where t.id = any (v_ids) and t.status <> 'active'
       and not exists (select 1 from public.profile_tag_assignments a where a.profile_id = p_user and a.tag_id = t.id)
  ) then
    raise exception 'An inactive tag cannot be given';
  end if;

  delete from public.profile_tag_assignments a where a.profile_id = p_user and not (a.tag_id = any (v_ids));
  get diagnostics v_removed = row_count;
  insert into public.profile_tag_assignments (profile_id, tag_id, assigned_by)
    select p_user, x, auth.uid() from unnest(v_ids) x
    on conflict (profile_id, tag_id) do nothing;
  get diagnostics v_added = row_count;

  if v_added > 0 or v_removed > 0 then
    insert into public.audit_logs (actor_id, action, target, severity)
      values (auth.uid(), 'profile_tag.set_user', p_user::text || ': +' || v_added || ' -' || v_removed, 'info');
  end if;
  return cardinality(v_ids);
end;
$$;
revoke execute on function public.admin_set_user_tags(uuid, uuid[]) from public, anon;
grant execute on function public.admin_set_user_tags(uuid, uuid[]) to authenticated;

-- ------------------------------------------------------------------------------------------------------------ Access Control accepts the key
-- Same function as migration 20261007120000, with 'manage_tags' added to the known keys, and "a Master can only hand it out while they hold it".
CREATE OR REPLACE FUNCTION public.set_staff_permissions(p_user_id uuid, p_permissions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_actor_role public.staff_role := public.current_staff_role();
  v_target_role public.staff_role;
  v_old jsonb;
  v_perms jsonb := coalesce(p_permissions, '{}'::jsonb);
  v_known text[] := array[
    'view_dashboards', 'manage_users', 'view_user_profile', 'manage_admins', 'manage_agencies', 'manage_hosts', 'manage_coins',
    'run_payroll', 'edit_config', 'manage_infra', 'view_audit', 'impersonate', 'export_data', 'view_reports',
    'manage_live_requests', 'manage_lucky_box', 'manage_badges', 'manage_leaderboard_frame',
    'manage_profile_frames', 'manage_content', 'manage_system', 'monitor_lives', 'manage_levels', 'manage_support',
    'manage_tags'
  ];
  k text;
  v jsonb;
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  if v_actor_role is null or v_actor_role not in ('super_admin', 'admin') then
    raise exception 'Only a Super Admin or a Master can change an account''s permissions';
  end if;
  if p_user_id = v_actor then raise exception 'You cannot change your own permissions'; end if;

  select role, permissions into v_target_role, v_old from public.staff_roles where user_id = p_user_id;
  if v_target_role is null then raise exception 'That account has no staff role'; end if;
  if v_target_role = 'super_admin' then raise exception 'A Super Admin always has full access'; end if;
  if v_actor_role = 'admin' and not public.can_manage_staff_role('admin', v_target_role) then
    raise exception 'A Master can only change permissions of accounts below Master';
  end if;

  if jsonb_typeof(v_perms) <> 'object' then raise exception 'Permissions must be an object'; end if;
  for k, v in select * from jsonb_each(v_perms) loop
    if not (k = any (v_known)) then raise exception 'Unknown permission %', k; end if;
    if jsonb_typeof(v) <> 'boolean' then raise exception 'Permission % must be true or false', k; end if;
    -- a Master cannot give what they do not hold themselves
    if v_actor_role = 'admin' and v = 'true'::jsonb and coalesce(v_old ->> k, '') <> 'true' then
      if k = 'monitor_lives' then
        if not public.staff_can_ghost_watch() then raise exception 'You do not have "%" yourself, so you cannot give it', k; end if;
      elsif k = 'manage_tags' then
        if not public.staff_can_manage_tags() then raise exception 'You do not have "%" yourself, so you cannot give it', k; end if;
      elsif k in ('manage_levels', 'manage_support', 'view_user_profile') then
        if not public.staff_cap_on(k) then raise exception 'You do not have "%" yourself, so you cannot give it', k; end if;
      elsif not public.has_capability(k) then
        raise exception 'You do not have "%" yourself, so you cannot give it', k;
      end if;
    end if;
  end loop;

  update public.staff_roles set permissions = v_perms where user_id = p_user_id;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (v_actor, 'staff.permissions_changed', p_user_id::text || ' (' || v_target_role::text || ') ' || v_perms::text, 'warning');

  return v_perms;
end;
$function$;
