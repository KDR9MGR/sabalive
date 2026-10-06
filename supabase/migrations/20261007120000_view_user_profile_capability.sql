-- New capability "View user profile" (view_user_profile): open a user's profile page, read-only, including the
-- sign-in & devices card. On by default for a Master (an explicit false blocks it, like manage_levels), off for every
-- other role until granted. The page's action buttons keep their own capability (manage_users); the database side here:
--   staff_can()              learns the key (a Global / Country / Sub Admin or Agency account with it explicitly on)
--   wallets, user_bans       new permissive SELECT policies for it (the profile shows the coin balance and the bans)
--   admin_user_login_info    gate becomes staff_cap_on('view_user_profile') and no longer also needs manage_users
--   set_staff_permissions    accepts the key; a Master can only hand it out while they hold it
-- Rollback: supabase/rollbacks/20261007120000_down.sql.
create or replace function public.staff_can(p_key text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.is_admin_or_above(), false)
    or exists (
      select 1 from public.staff_roles s
       where s.user_id = auth.uid()
         and nullif(s.permissions ->> p_key, '')::boolean is true
         and (
           p_key in ('manage_agencies', 'manage_coins', 'manage_live_requests', 'manage_lucky_box', 'manage_badges',
                     'manage_leaderboard_frame', 'manage_profile_frames', 'manage_content', 'view_reports',
                     'manage_levels', 'manage_support', 'edit_config', 'view_audit', 'monitor_lives', 'view_user_profile')
           or (p_key = 'manage_users' and s.role in ('global_admin', 'country_admin', 'sub_admin'))
           or (p_key = 'run_payroll')
         )
    );
$$;

drop policy if exists "Granted view_user_profile: select wallets" on public.wallets;
create policy "Granted view_user_profile: select wallets" on public.wallets for select
  using ((select public.staff_can('view_user_profile')));
drop policy if exists "Granted view_user_profile: select user_bans" on public.user_bans;
create policy "Granted view_user_profile: select user_bans" on public.user_bans for select
  using ((select public.staff_can('view_user_profile')));

-- admin_user_login_info
CREATE OR REPLACE FUNCTION public.admin_user_login_info(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user auth.users%rowtype;
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Only admins can view login details';
  end if;

  select * into v_user from auth.users where id = p_user;
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'email', v_user.email,
    'phone', v_user.phone,
    'created_at', v_user.created_at,
    'last_sign_in_at', v_user.last_sign_in_at,
    'email_confirmed_at', v_user.email_confirmed_at,
    'banned_until', v_user.banned_until,
    'providers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'provider', i.provider,
               'created_at', i.created_at,
               'last_sign_in_at', i.last_sign_in_at)
             order by i.created_at)
        from auth.identities i where i.user_id = p_user
    ), '[]'::jsonb),
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object(
               'device_id', d.device_id,
               'platform', d.platform,
               'model', d.model,
               'first_seen_at', d.first_seen_at,
               'last_seen_at', d.last_seen_at)
             order by d.last_seen_at desc)
        from public.user_devices d where d.user_id = p_user
    ), '[]'::jsonb),
    'logins', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.created_at desc)
        from (
          select method, device_id, platform, model, ip, created_at
            from public.user_login_events
           where user_id = p_user
           order by created_at desc
           limit 20
        ) e
    ), '[]'::jsonb),
    'active_session', (
      select jsonb_build_object(
               'device_id', s.device_id, 'platform', s.platform,
               'model', s.model, 'signed_in_at', s.signed_in_at)
        from public.user_active_session s where s.user_id = p_user
    )
  );
end;
$function$;

-- set_staff_permissions
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
    'manage_profile_frames', 'manage_content', 'manage_system', 'monitor_lives', 'manage_levels', 'manage_support'
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
