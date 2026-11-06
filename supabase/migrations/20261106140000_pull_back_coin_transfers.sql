-- Pull back a COIN TRANSFER (wallet to wallet), by permission.
--
-- Until now only a coin GRANT could be pulled back (pull_back_coin_grant, Master only) or a whole balance (admin_pull_back_all_coins). A wallet transfer
-- (transfer_coins_down: Master -> Global -> Country -> Sub -> Agency -> user) had no way back. This adds one:
--   * the capability `pull_back_coins` ("Pull back coin transfers" in Access Control): Super Admin always, a Master unless an explicit false blocks it,
--     any other panel account (Global / Country / Sub Admin, Agency) ONLY when it is explicitly granted (staff_can_pull_back_coins());
--   * pull_back_coin_transfer(transfer, reason): takes exactly the transferred coins back from the RECIPIENT and returns them to the SENDER, in two
--     ledger rows tied to the transfer. Who may use it on which transfer: a Master / Super Admin on any transfer; every other account only on a
--     transfer THEY sent (so a Global Admin cannot reach into another Global Admin's chain);
--   * all or nothing: it refuses when the recipient has already spent below the transferred amount (no partial pull-back, no negative wallet), a reason of
--     at least 3 characters is required, and a transfer can be pulled back ONCE (coin_transfers.pulled_back_at / pulled_back_by, so the panel can show it);
--   * the recipient's row is a 'grant_reversal' (so they get the usual "reclaimed from your wallet by an admin" push and it reads like every other pull-back);
--     the sender's row is a 'transfer_in'. No new ledger kind, so wallet_ledger_kind_check is untouched; one audit-log row (warning) per pull-back.
--
-- Additive only: two nullable columns with no default (no table rewrite), one helper, one new function. Nothing the shipped apps call changes.
-- Rollback: supabase/rollbacks/20261106140000_down.sql.
set local lock_timeout = '5s';

alter table public.coin_transfers add column if not exists pulled_back_at timestamptz;
alter table public.coin_transfers add column if not exists pulled_back_by uuid;

create or replace function public.staff_can_pull_back_coins()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(case public.current_staff_role()
    when 'super_admin' then true
    when 'admin' then coalesce(
      (select nullif(s.permissions ->> 'pull_back_coins', '')::boolean from public.staff_roles s where s.user_id = auth.uid()), true)
    else coalesce(
      (select nullif(s.permissions ->> 'pull_back_coins', '')::boolean from public.staff_roles s where s.user_id = auth.uid()), false)
  end, false);
$$;
revoke execute on function public.staff_can_pull_back_coins() from public, anon;
grant execute on function public.staff_can_pull_back_coins() to authenticated;

create or replace function public.pull_back_coin_transfer(p_transfer_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_role public.staff_role := public.current_staff_role();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_t public.coin_transfers;
  v_bal bigint;
begin
  if v_me is null or not coalesce(public.staff_can_pull_back_coins(), false) then
    raise exception 'You do not have permission to pull back coin transfers';
  end if;
  if length(v_reason) < 3 then
    raise exception 'Give a reason (at least 3 characters)';
  end if;

  select * into v_t from public.coin_transfers where id = p_transfer_id for update;
  if not found then
    raise exception 'That transfer does not exist';
  end if;
  if v_t.pulled_back_at is not null then
    raise exception 'This transfer has already been pulled back';
  end if;
  if v_t.sender_id is distinct from v_me and v_role not in ('super_admin', 'admin') then
    raise exception 'You can only pull back transfers you sent';
  end if;
  if v_t.sender_id is null or v_t.recipient_id is null or v_t.recipient_id = v_t.sender_id then
    raise exception 'This transfer cannot be pulled back';
  end if;

  -- lock both wallets (always in the same order) so the balance checked is the balance taken from
  perform 1 from public.wallets where profile_id in (v_t.sender_id, v_t.recipient_id) order by profile_id for update;
  select w.coins into v_bal from public.wallets w where w.profile_id = v_t.recipient_id;
  if coalesce(v_bal, 0) < v_t.coins then
    raise exception 'Cannot pull back: the recipient has only % of the % coins left', coalesce(v_bal, 0), v_t.coins;
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (v_t.recipient_id, 'grant_reversal', 'coins', -v_t.coins, 'coin_transfers', v_t.id, 'Pulled back by admin: ' || left(v_reason, 200));
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (v_t.sender_id, 'transfer_in', 'coins', v_t.coins, 'coin_transfers', v_t.id, 'Transfer pulled back: ' || left(v_reason, 200));

  update public.coin_transfers set pulled_back_at = now(), pulled_back_by = v_me where id = v_t.id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (v_me, 'coin_transfer.pull_back',
            v_t.id::text || ' (' || v_t.coins || ' coins, ' || v_t.recipient_id::text || ' back to ' || v_t.sender_id::text || ') ' || left(v_reason, 200),
            'warning');

  return jsonb_build_object('transfer_id', v_t.id, 'coins', v_t.coins, 'from', v_t.recipient_id, 'to', v_t.sender_id);
end;
$$;
revoke execute on function public.pull_back_coin_transfer(uuid, text) from public, anon;
grant execute on function public.pull_back_coin_transfer(uuid, text) to authenticated;

-- Access Control accepts the new key. This is set_staff_permissions exactly as it is live (migration 20261026140000), with 'pull_back_coins' added to the
-- accepted keys and one branch so a Master can only hand it on if they hold it themselves (like manage_tags). Nothing else in it changes.
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
    'manage_tags', 'reset_diamonds', 'pull_back_coins'
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
