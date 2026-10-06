-- Per-account capability grants for lower roles (Super Admin -> Access Control).
-- A Global / Country / Sub Admin (and, for payroll, an Agency) whose permissions JSON
-- has the key set to true may now act on it: manage_users -> restrict / lift /
-- change status of users; run_payroll -> see and decide withdrawals. Everything else
-- stays role-gated. The functions below are re-created from their live definitions
-- with ONLY the first role gate swapped from is_admin_or_above() to staff_can(key);
-- require_capability(key) still runs after it, so an explicit false still blocks.
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
           (p_key = 'manage_users' and s.role in ('global_admin', 'country_admin', 'sub_admin'))
           or (p_key = 'run_payroll' and s.role in ('global_admin', 'country_admin', 'sub_admin', 'agency_manager'))
         )
    );
$$;
revoke execute on function public.staff_can(text) from public, anon;
grant execute on function public.staff_can(text) to authenticated;

-- set_profile_status
CREATE OR REPLACE FUNCTION public.set_profile_status(p_profile_id uuid, p_status text)
 RETURNS profiles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.profiles;
begin
  if not public.staff_can('manage_users') then
    raise exception 'Only admins can change a user''s status';
  end if;
  perform public.require_capability('manage_users');
  if p_status not in ('active', 'inactive', 'suspended') then
    raise exception 'Invalid status %', p_status;
  end if;

  if p_status = 'suspended' then
    perform public.ban_user(p_profile_id, array['account'], 'permanent', 'Suspended from the admin panel');
  elsif p_status = 'active' then
    perform public.lift_user_bans(p_profile_id, 'Reactivated from the admin panel');
  else
    -- inactive is not a ban, but it does end an ID ban
    perform public.lift_user_bans(p_profile_id, 'Set inactive from the admin panel', array['account']);
    update public.profiles set status = 'inactive' where id = p_profile_id;
  end if;

  select * into v_row from public.profiles where id = p_profile_id;
  return v_row;
end;
$function$;

-- ban_user
CREATE OR REPLACE FUNCTION public.ban_user(p_user uuid, p_kinds text[], p_duration text, p_reason text DEFAULT NULL::text)
 RETURNS SETOF user_bans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_kind text;
  v_kinds text[];
  v_ends timestamptz;
  v_ban public.user_bans;
begin
  if not public.staff_can('manage_users') then
    raise exception 'Only admins can ban users';
  end if;
  perform public.require_capability('manage_users');
  if p_user = auth.uid() then
    raise exception 'You can''t ban yourself';
  end if;
  if exists (select 1 from public.staff_roles where user_id = p_user) then
    raise exception 'Staff accounts can''t be banned here';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'User not found';
  end if;
  if p_duration not in ('7d', '30d', 'permanent') then
    raise exception 'Duration must be 7d, 30d or permanent';
  end if;
  select array_agg(distinct k) into v_kinds from unnest(p_kinds) k;
  if v_kinds is null or not (v_kinds <@ array['live', 'account', 'device']) then
    raise exception 'Choose at least one of: live, account, device';
  end if;

  v_ends := case p_duration
    when '7d' then now() + interval '7 days'
    when '30d' then now() + interval '30 days'
    else null
  end;

  foreach v_kind in array v_kinds loop
    update public.user_bans
       set lifted_at = now(), lifted_by = auth.uid(), lift_note = 'Replaced by a new ban'
     where user_id = p_user and kind = v_kind and public.ban_active(user_bans);

    insert into public.user_bans (user_id, kind, ends_at, reason, created_by)
    values (p_user, v_kind, v_ends, nullif(trim(p_reason), ''), auth.uid())
    returning * into v_ban;

    -- an ID ban and a device ban both cover every device the user has used
    if v_kind in ('account', 'device') then
      insert into public.banned_devices (device_id, ban_id)
      select device_id, v_ban.id from public.user_devices where user_id = p_user
      on conflict do nothing;
    end if;

    return next v_ban;
  end loop;

  -- get them out of any live right now
  if v_kinds && array['live', 'account'] then
    update public.live_streams set status = 'ended', ended_at = now()
     where host_id = p_user and status = 'live';
    update public.live_stream_viewers set left_at = now()
     where viewer_id = p_user and left_at is null;
    delete from public.live_stream_seats where occupant_id = p_user;
  end if;

  if 'account' = any (v_kinds) then
    perform public.sync_account_ban(p_user);
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (
    auth.uid(), 'user.banned',
    p_user::text || ' -> ' || array_to_string(v_kinds, '+') || ' for ' || p_duration,
    'warning'
  );
end;
$function$;

-- lift_ban
CREATE OR REPLACE FUNCTION public.lift_ban(p_ban_id uuid, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ban public.user_bans;
begin
  if not public.staff_can('manage_users') then
    raise exception 'Only admins can lift bans';
  end if;
  perform public.require_capability('manage_users');

  update public.user_bans
     set lifted_at = now(), lifted_by = auth.uid(), lift_note = nullif(trim(p_note), '')
   where id = p_ban_id and lifted_at is null
   returning * into v_ban;
  if not found then
    raise exception 'That ban was not found or is already lifted';
  end if;

  if v_ban.kind = 'account' then
    perform public.sync_account_ban(v_ban.user_id);
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.ban_lifted', v_ban.user_id::text || ' -> ' || v_ban.kind, 'info');
end;
$function$;

-- lift_user_bans
CREATE OR REPLACE FUNCTION public.lift_user_bans(p_user uuid, p_note text DEFAULT NULL::text, p_kinds text[] DEFAULT NULL::text[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count integer;
begin
  if not public.staff_can('manage_users') then
    raise exception 'Only admins can lift bans';
  end if;
  perform public.require_capability('manage_users');

  update public.user_bans
     set lifted_at = now(), lifted_by = auth.uid(), lift_note = nullif(trim(p_note), '')
   where user_id = p_user
     and public.ban_active(user_bans)
     and (p_kinds is null or kind = any (p_kinds));
  get diagnostics v_count = row_count;

  perform public.sync_account_ban(p_user);

  if v_count > 0 then
    insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'user.ban_lifted', p_user::text || ' -> all (' || v_count || ')', 'info');
  end if;
  return v_count;
end;
$function$;

-- decide_withdrawal
CREATE OR REPLACE FUNCTION public.decide_withdrawal(p_withdrawal_id uuid, p_approve boolean)
 RETURNS withdrawals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.withdrawals;
begin
  if not public.staff_can('run_payroll') then
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

-- reads those pages need
drop policy if exists "Granted staff see bans" on public.user_bans;
create policy "Granted staff see bans" on public.user_bans for select using (public.staff_can('manage_users'));
drop policy if exists "Granted staff see withdrawals" on public.withdrawals;
create policy "Granted staff see withdrawals" on public.withdrawals for select using (public.staff_can('run_payroll'));
