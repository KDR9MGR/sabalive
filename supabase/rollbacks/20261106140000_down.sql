-- Down script for supabase/migrations/20261106140000_pull_back_coin_transfers.sql
-- Applied BY HAND only. Removes the two functions and the two bookkeeping columns. Cannot be undone by this script: transfers already pulled back
-- (their ledger rows 'grant_reversal' / 'transfer_in' tied to the transfer and their audit-log rows stay; the columns that said WHICH transfer was
-- pulled back are dropped, so the panel would offer those transfers again: do not run this after pull-backs happened unless you accept that, and
-- note that a second pull-back of such a transfer would then be possible only if the function existed, which it no longer does).
begin;
set local lock_timeout = '5s';
-- Access Control back to the previous list of keys (the live body before this migration, from 20261026140000). A saved 'pull_back_coins' permission stays in
-- staff_roles.permissions but does nothing once the function is gone; remove it from the accounts if you want it clean.
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
    'manage_tags', 'reset_diamonds'
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
      elsif k in ('manage_levels', 'manage_support', 'view_user_profile', 'reset_diamonds') then
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
drop function if exists public.pull_back_coin_transfer(uuid, text);
drop function if exists public.staff_can_pull_back_coins();
alter table public.coin_transfers drop column if exists pulled_back_by;
alter table public.coin_transfers drop column if exists pulled_back_at;
commit;
