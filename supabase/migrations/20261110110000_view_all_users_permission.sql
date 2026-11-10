-- A permission that lifts the "own chain" limit for chosen accounts (owner, 2026-11-10: "provide selective users able to see all user data just like master and admin ... make a permission").
-- `view_all_users` (Access Control, Super Admin or Master gives it to a Global / Country / Sub Admin or Agency account): while "Limit each admin to their own chain" is ON, an
-- account with this permission is treated as unlimited for READS, exactly like a Master: staff_scope_applies() answers no for it, and every row policy of 20261102100000 starts with
-- "does this apply to me?" (profiles, host_profiles, agencies, staff_roles, wallets, coin_transfers). Those policies are all RESTRICTIVE and FOR SELECT, so this only widens what the
-- account may SEE; it adds no write power (approving, editing, coins and the rest stay on the account's own permissions and place in the ladder). Without the permission nothing changes.
-- Lifting the chain limit alone is not "like a Master": other (permissive) policies still decide what a Global / Country / Sub Admin / Agency account may read (for example wallets only of
-- hosts in its scope, staff only below it). So an account with the permission also gets READ-only policies on the people-and-coins tables a Master reads: wallets, wallet_ledger,
-- staff_roles, coin_transfers, coin_grants, gift_transactions. NOT included: withdrawals (needs Run payroll), host applications (the agency's own workflow), live requests (needs Live requests),
-- bank / payout details, sign-in and device data (needs "Open a user's profile page"). Everything stays read-only.
-- set_staff_permissions is re-emitted exactly as it is live (it already carries 'pull_back_coins' from 20261106140000) with 'view_all_users' added: it is a known key, and a Master can
-- give it (a Master holds it by default, like staff_cap_on keys). Rollback: supabase/rollbacks/20261110110000_down.sql.
set local lock_timeout = '5s';

create or replace function public.staff_scope_applies()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.staff_scope_limited()
                  and public.current_staff_role() in ('global_admin', 'country_admin', 'sub_admin', 'agency_manager')
                  and not coalesce((select nullif(s.permissions ->> 'view_all_users', '')::boolean from public.staff_roles s where s.user_id = auth.uid()), false),
                  false);
$$;
revoke execute on function public.staff_scope_applies() from public, anon;
grant execute on function public.staff_scope_applies() to authenticated;

-- true for a Global / Country / Sub Admin / Agency account that was given view_all_users (Master and Super Admin already read everything and are not asked)
create or replace function public.staff_views_all_users()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.staff_roles s
                  where s.user_id = auth.uid()
                    and s.role in ('global_admin', 'country_admin', 'sub_admin', 'agency_manager')
                    and nullif(s.permissions ->> 'view_all_users', '')::boolean is true);
$$;
revoke execute on function public.staff_views_all_users() from public, anon;
grant execute on function public.staff_views_all_users() to authenticated;

drop policy if exists "Granted view_all_users: select wallets" on public.wallets;
create policy "Granted view_all_users: select wallets" on public.wallets for select to authenticated using ((select public.staff_views_all_users()));
drop policy if exists "Granted view_all_users: select wallet_ledger" on public.wallet_ledger;
create policy "Granted view_all_users: select wallet_ledger" on public.wallet_ledger for select to authenticated using ((select public.staff_views_all_users()));
drop policy if exists "Granted view_all_users: select staff_roles" on public.staff_roles;
create policy "Granted view_all_users: select staff_roles" on public.staff_roles for select to authenticated using ((select public.staff_views_all_users()));
drop policy if exists "Granted view_all_users: select coin_transfers" on public.coin_transfers;
create policy "Granted view_all_users: select coin_transfers" on public.coin_transfers for select to authenticated using ((select public.staff_views_all_users()));
drop policy if exists "Granted view_all_users: select coin_grants" on public.coin_grants;
create policy "Granted view_all_users: select coin_grants" on public.coin_grants for select to authenticated using ((select public.staff_views_all_users()));
drop policy if exists "Granted view_all_users: select gift_transactions" on public.gift_transactions;
create policy "Granted view_all_users: select gift_transactions" on public.gift_transactions for select to authenticated using ((select public.staff_views_all_users()));

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
    'manage_tags', 'reset_diamonds', 'pull_back_coins', 'view_all_users'
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
      elsif k = 'pull_back_coins' then
        if not public.staff_can_pull_back_coins() then raise exception 'You do not have "%" yourself, so you cannot give it', k; end if;
      elsif k in ('manage_levels', 'manage_support', 'view_user_profile', 'reset_diamonds', 'view_all_users') then
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
