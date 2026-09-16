-- Per-user capability overrides on top of the role.
--
-- staff_roles.permissions (jsonb) holds { <key>: true|false }. Effective value
-- for a key = permissions[key] ?? role_baseline(role, key). This is DENY-ONLY on
-- the server: the pre-existing role checks in every RPC below still gate, and a
-- `false` in permissions additionally blocks; a `true` beyond the role baseline
-- only changes what the admin panel shows, it does not grant server capability.
--
-- The 12 keys mirror src/lib/capabilities.js in the sabaliveadmin repo — the two
-- copies of the baseline (there and role_baseline() here) must stay in sync.

create function public.role_baseline(p_role public.staff_role, p_key text)
returns boolean language sql immutable set search_path = public as $$
  select case p_role
    when 'super_admin'    then true
    when 'admin'          then p_key in ('view_dashboards','manage_users','manage_agencies','manage_hosts','manage_coins','export_data')
    when 'agency_manager' then p_key in ('view_dashboards','manage_hosts','export_data')
    when 'sub_admin'      then p_key in ('view_dashboards','manage_hosts')
    else false end;
$$;

create function public.has_capability(p_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when public.current_staff_role() is null then false
    when public.current_staff_role() = 'super_admin' then true
    else coalesce(
      nullif((select permissions ->> p_key from public.staff_roles where user_id = auth.uid()), '')::boolean,
      public.role_baseline(public.current_staff_role(), p_key)
    )
  end;
$$;
grant execute on function public.has_capability(text) to authenticated;

create function public.require_capability(p_key text)
returns void language plpgsql stable set search_path = public as $$
begin
  if not public.has_capability(p_key) then
    raise exception 'Your account is not permitted to %', p_key using errcode = '42501';
  end if;
end;
$$;
grant execute on function public.require_capability(text) to authenticated;

-- ============================================================================
-- Re-emit the privileged RPCs verbatim, each with one require_capability() line
-- added right after its existing role guard.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.broadcast_notification(p_kind text, p_body text, p_audience text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count integer;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can broadcast notifications';
  end if;
  perform public.require_capability('manage_users');
  if coalesce(trim(p_body), '') = '' then
    raise exception 'Notification body is required';
  end if;
  if p_audience not in ('all', 'hosts', 'agencies', 'sub_admins') then
    raise exception 'Unknown audience %', p_audience;
  end if;

  with targets as (
    select p.id
    from public.profiles p
    where p_audience = 'all'
       or (p_audience = 'hosts' and p.is_host)
       or (p_audience = 'agencies' and exists (
             select 1 from public.staff_roles sr
             where sr.user_id = p.id and sr.role = 'agency_manager'))
       or (p_audience = 'sub_admins' and exists (
             select 1 from public.staff_roles sr
             where sr.user_id = p.id and sr.role = 'sub_admin'))
  ), ins as (
    insert into public.notifications (profile_id, kind, body)
    select id, coalesce(nullif(trim(p_kind), ''), 'announcement'), p_body from targets
    returning 1
  )
  select count(*) into v_count from ins;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'notification.broadcast', p_audience || ' x' || v_count, 'info');

  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.decide_host_application(p_application_id uuid, p_approve boolean)
 RETURNS host_applications
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.host_applications;
begin
  if not public.is_staff() then
    raise exception 'Only staff can decide host applications';
  end if;

  select * into v_row from public.host_applications
    where id = p_application_id and status in ('pending', 'under_review');
  if v_row.id is null then
    raise exception 'Host application not found or already decided';
  end if;

  -- manages_agency() already folds in is_admin_or_above(); a NULL agency
  -- (direct application) resolves to admin-only.
  if not public.manages_agency(v_row.agency_id) then
    raise exception 'Not allowed to decide this host application';
  end if;
  perform public.require_capability('manage_hosts');

  update public.host_applications
    set status      = case when p_approve then 'approved' else 'rejected' end,
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = p_application_id
    returning * into v_row;

  if p_approve then
    insert into public.host_profiles (profile_id, agency_id)
      values (v_row.applicant_id, v_row.agency_id)
      on conflict (profile_id)
        do update set agency_id = excluded.agency_id, updated_at = now();
    update public.profiles set is_host = true where id = v_row.applicant_id;
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(),
            case when p_approve then 'host_application.approved' else 'host_application.rejected' end,
            v_row.applicant_id::text,
            'info');

  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.decide_kyc(p_verification_id uuid, p_approve boolean)
 RETURNS kyc_verifications
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.kyc_verifications;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can decide KYC verifications';
  end if;
  perform public.require_capability('manage_hosts');

  select * into v_row from public.kyc_verifications
    where id = p_verification_id and status = 'pending';
  if v_row.id is null then
    raise exception 'KYC verification not found or already decided';
  end if;

  update public.kyc_verifications
    set status      = case when p_approve then 'verified' else 'rejected' end,
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = p_verification_id
    returning * into v_row;

  if p_approve then
    update public.profiles set verified = true where id = v_row.profile_id;
  end if;

  -- keep the host/agency-facing kyc_status in sync when the person is a host
  update public.host_profiles
    set kyc_status = case when p_approve then 'verified' else 'rejected' end,
        updated_at = now()
    where profile_id = v_row.profile_id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(),
            case when p_approve then 'kyc.approved' else 'kyc.rejected' end,
            v_row.profile_id::text,
            'info');

  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.decide_transfer_request(p_request_id uuid, p_approve boolean)
 RETURNS transfer_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.transfer_requests;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can decide transfer requests';
  end if;
  perform public.require_capability('manage_agencies');

  select * into v_row from public.transfer_requests where id = p_request_id and status = 'pending';
  if v_row.id is null then
    raise exception 'Transfer request not found or already decided';
  end if;

  if p_approve then
    update public.transfer_requests set status = 'approved', decided_by = auth.uid(), decided_at = now()
      where id = p_request_id returning * into v_row;

    if v_row.subject_type = 'host' then
      update public.host_profiles set agency_id = v_row.to_agency_id where profile_id = v_row.subject_id;
    else
      update public.staff_roles set agency_id = v_row.to_agency_id where user_id = v_row.subject_id;
    end if;
  else
    update public.transfer_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now()
      where id = p_request_id returning * into v_row;
  end if;

  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.decide_withdrawal(p_withdrawal_id uuid, p_approve boolean)
 RETURNS withdrawals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.withdrawals;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can decide withdrawals';
  end if;
  perform public.require_capability('run_payroll');

  select * into v_row from public.withdrawals where id = p_withdrawal_id and status = 'pending';
  if v_row.id is null then
    raise exception 'Withdrawal not found or already decided';
  end if;

  if p_approve then
    update public.withdrawals set status = 'paid', processed_at = now(), processed_by = auth.uid()
      where id = p_withdrawal_id returning * into v_row;
  else
    update public.withdrawals set status = 'rejected', processed_at = now(), processed_by = auth.uid()
      where id = p_withdrawal_id returning * into v_row;
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
      values (v_row.profile_id, 'withdrawal', 'diamonds', v_row.diamonds, 'withdrawals', v_row.id, 'Withdrawal rejected — refunded');
  end if;

  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.distribute_coins(p_per_recipient bigint, p_audience text, p_role text DEFAULT NULL::text, p_recipient_ids uuid[] DEFAULT NULL::uuid[], p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ids uuid[];
  v_count integer;
  v_total bigint;
  v_balance bigint;
begin
  if not public.can_mint_coins() then
    raise exception 'Not allowed to distribute coins';
  end if;
  perform public.require_capability('manage_coins');
  if p_per_recipient is null or p_per_recipient <= 0 then
    raise exception 'Amount per recipient must be positive';
  end if;
  if p_per_recipient > 2147483647 then
    raise exception 'Amount per recipient is too large';
  end if;

  select array_agg(id) into v_ids from (
    select p.id
    from public.profiles p
    where case p_audience
      when 'all' then true
      when 'users' then p.id = any(coalesce(p_recipient_ids, '{}'::uuid[]))
      when 'role' then case p_role
        when 'host'      then p.is_host
        when 'agency'    then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'agency_manager')
        when 'sub_admin' then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'sub_admin')
        when 'staff'     then exists (select 1 from public.staff_roles s where s.user_id = p.id)
        else false end
      else false end
  ) t;

  v_count := coalesce(array_length(v_ids, 1), 0);
  if v_count = 0 then
    raise exception 'No recipients matched';
  end if;

  v_total := v_count::bigint * p_per_recipient;

  select (minted_total - distributed_total) into v_balance from public.coin_treasury where id = true;
  if v_total > v_balance then
    raise exception 'Treasury balance % is short of the % coins this distribution needs', v_balance, v_total;
  end if;

  -- make sure every recipient has a wallet row (normally created on signup)
  insert into public.wallets (profile_id)
    select unnest(v_ids) on conflict (profile_id) do nothing;

  -- one coin_grants row per recipient -> coin_grants_after_insert credits the wallet
  insert into public.coin_grants (granted_to, granted_by, coins, note)
    select unnest(v_ids), auth.uid(), p_per_recipient::integer,
           coalesce(nullif(trim(p_note), ''), 'Treasury distribution');

  update public.coin_treasury
    set distributed_total = distributed_total + v_total,
        updated_at = now(),
        updated_by = auth.uid()
    where id = true;

  insert into public.coin_treasury_events (event_type, coins, per_recipient, audience, recipients, note, created_by)
    values ('distribution', v_total, p_per_recipient,
            case when p_audience = 'role' then 'role:' || coalesce(p_role, '?') else p_audience end,
            v_count, p_note, auth.uid());

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'treasury.distribute',
            v_total::text || ' to ' || v_count::text || ' (' ||
            case when p_audience = 'role' then coalesce(p_role, '?') else p_audience end || ')',
            'warning');

  return jsonb_build_object('recipients', v_count, 'total', v_total, 'balance', v_balance - v_total);
end;
$function$;

CREATE OR REPLACE FUNCTION public.generate_host_code(p_expires_at timestamp with time zone, p_label text DEFAULT NULL::text, p_max_uses integer DEFAULT 1)
 RETURNS host_codes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_code text;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_row public.host_codes;
  i integer;
begin
  if not public.is_staff() then
    raise exception 'Only staff can generate host codes';
  end if;
  perform public.require_capability('manage_hosts');
  if p_expires_at is null or p_expires_at <= now() then
    raise exception 'Expiry must be in the future';
  end if;
  if coalesce(p_max_uses, 1) < 1 or coalesce(p_max_uses, 1) > 500 then
    raise exception 'max_uses must be 1..500';
  end if;

  loop
    v_code := '';
    for i in 1..8 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.host_codes where code = v_code);
  end loop;

  insert into public.host_codes (code, agency_id, created_by, label, max_uses, expires_at)
  values (v_code, public.current_agency_id(), auth.uid(),
          nullif(trim(p_label), ''), coalesce(p_max_uses, 1), p_expires_at)
  returning * into v_row;
  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.generate_reseller_code(p_expires_at timestamp with time zone, p_label text DEFAULT NULL::text, p_max_uses integer DEFAULT 1)
 RETURNS reseller_codes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_code text;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_row public.reseller_codes;
  i integer;
begin
  if not public.is_staff() then
    raise exception 'Only staff can generate reseller codes';
  end if;
  perform public.require_capability('manage_agencies');
  if p_expires_at is null or p_expires_at <= now() then
    raise exception 'Expiry must be in the future';
  end if;
  if coalesce(p_max_uses, 1) < 1 or coalesce(p_max_uses, 1) > 500 then
    raise exception 'max_uses must be 1..500';
  end if;

  loop
    v_code := 'R';
    for i in 1..7 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.reseller_codes where code = v_code);
  end loop;

  insert into public.reseller_codes (code, agency_id, created_by, label, max_uses, expires_at)
  values (v_code, public.current_agency_id(), auth.uid(),
          nullif(trim(p_label), ''), coalesce(p_max_uses, 1), p_expires_at)
  returning * into v_row;
  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.mint_coins(p_coins bigint, p_note text DEFAULT NULL::text)
 RETURNS coin_treasury
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.coin_treasury;
begin
  if not public.can_mint_coins() then
    raise exception 'Not allowed to generate coins';
  end if;
  perform public.require_capability('manage_coins');
  if p_coins is null or p_coins <= 0 then
    raise exception 'Amount must be positive';
  end if;

  update public.coin_treasury
    set minted_total = minted_total + p_coins,
        updated_at = now(),
        updated_by = auth.uid()
    where id = true
    returning * into v_row;

  insert into public.coin_treasury_events (event_type, coins, note, created_by)
    values ('mint', p_coins, p_note, auth.uid());

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'treasury.mint', p_coins::text, 'warning');

  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_host_code_status(p_code_id uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_code public.host_codes;
  r record;
begin
  select * into v_code from public.host_codes where id = p_code_id;
  if v_code.id is null then
    raise exception 'Code not found';
  end if;
  if not (public.is_admin_or_above() or public.manages_agency(v_code.agency_id)) then
    raise exception 'Not allowed to manage this code';
  end if;
  perform public.require_capability('manage_hosts');
  if p_status not in ('active', 'banned') then
    raise exception 'status must be active or banned';
  end if;

  update public.host_codes set status = p_status where id = p_code_id;

  if p_status = 'banned' then
    for r in
      update public.host_grants set status = 'banned', ban_reason = 'code disabled'
      where code_id = p_code_id and status = 'active'
      returning profile_id
    loop
      perform public.sync_host_flag(r.profile_id);
    end loop;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_host_grant_status(p_grant_id uuid, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_grant public.host_grants;
begin
  select * into v_grant from public.host_grants where id = p_grant_id;
  if v_grant.id is null then
    raise exception 'Grant not found';
  end if;
  if not (public.is_admin_or_above() or public.manages_agency(v_grant.agency_id)) then
    raise exception 'Not allowed to manage this grant';
  end if;
  perform public.require_capability('manage_hosts');
  if p_status not in ('active', 'revoked', 'banned') then
    raise exception 'invalid status';
  end if;

  update public.host_grants
    set status = p_status,
        ban_reason = case when p_status = 'active' then null else nullif(trim(p_reason), '') end
  where id = p_grant_id;

  perform public.sync_host_flag(v_grant.profile_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_profile_status(p_profile_id uuid, p_status text)
 RETURNS profiles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.profiles;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can change a user''s status';
  end if;
  perform public.require_capability('manage_users');
  if p_status not in ('active', 'inactive', 'suspended') then
    raise exception 'Invalid status %', p_status;
  end if;

  update public.profiles set status = p_status where id = p_profile_id returning * into v_row;
  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_reseller_code_status(p_code_id uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_code public.reseller_codes;
begin
  select * into v_code from public.reseller_codes where id = p_code_id;
  if v_code.id is null then raise exception 'Code not found'; end if;
  if not (public.is_admin_or_above() or public.manages_agency(v_code.agency_id)) then
    raise exception 'Not allowed to manage this code';
  end if;
  perform public.require_capability('manage_agencies');
  if p_status not in ('active', 'banned') then raise exception 'status must be active or banned'; end if;
  update public.reseller_codes set status = p_status where id = p_code_id;
  if p_status = 'banned' then
    update public.reseller_grants set status = 'banned', ban_reason = 'code disabled'
    where code_id = p_code_id and status = 'active';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_reseller_grant_status(p_grant_id uuid, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_grant public.reseller_grants;
begin
  select * into v_grant from public.reseller_grants where id = p_grant_id;
  if v_grant.id is null then raise exception 'Grant not found'; end if;
  if not (public.is_admin_or_above() or public.manages_agency(v_grant.agency_id)) then
    raise exception 'Not allowed to manage this grant';
  end if;
  perform public.require_capability('manage_agencies');
  if p_status not in ('active', 'revoked', 'banned') then raise exception 'invalid status'; end if;
  update public.reseller_grants
    set status = p_status,
        ban_reason = case when p_status = 'active' then null else nullif(trim(p_reason), '') end
  where id = p_grant_id;
end;
$function$;
