-- Hierarchy stage 3: Global Admin. Sits below Master/Admin and Super Admin and
-- above Country Admin: it sees the WHOLE tree (every country admin, sub admin,
-- agency and host) and moves coins down through all of it. Same additive
-- pattern as stages 1 and 2 — and, as before:
--   * is_admin_or_above() is NOT widened. global_admin is a scoped role, not a
--     platform admin (no withdrawals, treasury, config, role grants ...).
--   * account creation stays Super Admin only.

-- ------------------------------------------------------------ capabilities
-- Same baseline as country_admin (keep in sync with src/lib/capabilities.js).
create or replace function public.role_baseline(p_role public.staff_role, p_key text)
returns boolean language sql immutable set search_path = public as $$
  select case p_role
    when 'super_admin'    then true
    when 'admin'          then p_key in ('view_dashboards','manage_users','manage_agencies','manage_hosts','manage_coins','export_data')
    when 'agency_manager' then p_key in ('view_dashboards','manage_hosts','export_data')
    when 'sub_admin'      then p_key in ('view_dashboards','manage_hosts')
    when 'country_admin'  then p_key in ('view_dashboards','manage_hosts')
    when 'global_admin'   then p_key in ('view_dashboards','manage_hosts')
    else false end;
$$;

-- ------------------------------------------------------------ scope
-- "Sees the whole staff tree": platform admins and the global admin.
create function public.is_global_scope()
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce(public.is_admin_or_above() or public.current_staff_role() = 'global_admin', false);
$$;
revoke execute on function public.is_global_scope() from public, anon;
grant execute on function public.is_global_scope() to authenticated;

create or replace function public.manages_agency(target_agency_id uuid)
returns boolean language sql stable
as $$
  select coalesce(
    public.is_admin_or_above()
      or (public.current_staff_role() in ('agency_manager', 'sub_admin')
          and public.current_agency_id() = target_agency_id)
      or (public.current_staff_role() = 'sub_admin'
          and public.owns_agency(target_agency_id))
      or (public.current_staff_role() = 'country_admin'
          and public.country_owns_agency(target_agency_id))
      or public.current_staff_role() = 'global_admin',
    false
  );
$$;

create or replace function public.in_country_scope_agency(p_agency_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce(
    public.is_global_scope()
    or (public.current_staff_role() = 'country_admin' and public.country_owns_agency(p_agency_id)),
    false);
$$;

-- coalesce: current_staff_role() is NULL for a non-staff caller, and
-- `IF NOT NULL` would silently skip the raise (see 20260930110000).
create or replace function public._assert_country_actor()
returns void language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.is_global_scope() or public.current_staff_role() = 'country_admin', false) then
    raise exception 'Only a global or country admin can do this';
  end if;
end;
$$;

-- ------------------------------------------------------------ visibility
create policy "Global admins see country admins and everyone below"
  on public.staff_roles for select
  using (
    public.current_staff_role() = 'global_admin'
    and role in ('country_admin', 'sub_admin', 'agency_manager')
  );

drop policy "Participants, owners and staff see coin transfers" on public.coin_transfers;
create policy "Participants, owners and staff see coin transfers"
  on public.coin_transfers for select
  using (
    sender_id = auth.uid() or recipient_id = auth.uid()
    or public.is_admin_or_above()
    or public.current_staff_role() = 'global_admin'
    or (agency_id is not null and public.manages_agency(agency_id))
    or (public.current_staff_role() = 'country_admin'
        and (public.owns_sub_admin(sender_id) or public.owns_sub_admin(recipient_id)))
  );

-- ------------------------------------------------------------ coin cascade
alter table public.coin_transfers drop constraint coin_transfers_recipient_kind_check;
alter table public.coin_transfers add constraint coin_transfers_recipient_kind_check
  check (recipient_kind in ('user', 'agency', 'sub_admin', 'country_admin'));

-- Replaces the stage-2 body; adds global_admin as a sender.
--   global_admin   -> any country admin, sub admin, agency manager, or plain user
--   country_admin  -> sub admin they own, agency manager under one of their sub
--                     admins, or any plain user
--   sub_admin      -> agency manager of an agency they own, or any plain user
--   agency_manager -> any plain user
create or replace function public.transfer_coins_down(p_recipient uuid, p_coins bigint, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_role public.staff_role := public.current_staff_role();
  v_rrole public.staff_role;
  v_ragency uuid;
  v_kind text := 'user';
  v_agency uuid := null;
  v_bal bigint;
  v_note text := nullif(trim(p_note), '');
begin
  if v_me is null then raise exception 'Sign in first'; end if;
  if v_role is null or v_role not in ('global_admin', 'country_admin', 'sub_admin', 'agency_manager') then
    raise exception 'Only a global admin, country admin, sub admin or agency can transfer coins from this panel';
  end if;
  if p_coins is null or p_coins <= 0 then raise exception 'Enter a valid amount'; end if;
  if p_coins > 2147483647 then raise exception 'Amount is too large'; end if;
  if p_recipient is null or p_recipient = v_me then raise exception 'Pick someone else as the recipient'; end if;
  if not exists (select 1 from public.profiles where id = p_recipient) then
    raise exception 'Recipient not found';
  end if;

  select role, agency_id into v_rrole, v_ragency from public.staff_roles where user_id = p_recipient;

  if v_rrole in ('super_admin', 'admin', 'global_admin') then
    raise exception 'Coins cannot be sent up or sideways to a global or platform admin';
  elsif v_rrole = 'country_admin' then
    if v_role <> 'global_admin' then
      raise exception 'Coins cannot be sent up or sideways to a country admin';
    end if;
    v_kind := 'country_admin';
  elsif v_rrole = 'sub_admin' then
    if v_role not in ('global_admin', 'country_admin') then
      raise exception 'Coins cannot be sent sideways to another sub admin';
    end if;
    if v_role = 'country_admin' and not public.owns_sub_admin(p_recipient) then
      raise exception 'That sub admin is not one of yours';
    end if;
    v_kind := 'sub_admin';
  elsif v_rrole = 'agency_manager' then
    if v_role = 'agency_manager' then
      raise exception 'An agency can only send coins to users';
    elsif v_role = 'sub_admin' then
      if not public.owns_agency(v_ragency) then raise exception 'That agency is not one of yours'; end if;
    elsif v_role = 'country_admin' then
      if not public.country_owns_agency(v_ragency) then raise exception 'That agency is not under any of your sub admins'; end if;
    end if;
    v_kind := 'agency';
    v_agency := v_ragency;
  elsif v_role = 'agency_manager' then
    v_agency := public.current_agency_id();
  end if;

  select coins into v_bal from public.wallets where profile_id = v_me for update;
  if coalesce(v_bal, 0) < p_coins then
    raise exception 'Not enough coins in your balance (you have %)', coalesce(v_bal, 0);
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
    values (v_me, 'transfer_out', 'coins', -p_coins, coalesce(v_note, 'Coin transfer'));
  insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
    values (p_recipient, 'transfer_in', 'coins', p_coins, coalesce(v_note, 'Coins received'));
  insert into public.coin_transfers (sender_id, recipient_id, coins, note, recipient_kind, agency_id)
    values (v_me, p_recipient, p_coins, v_note, v_kind, v_agency);

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'coins.transfer_down', p_coins::text || ' to ' || v_kind, 'info');

  return jsonb_build_object('ok', true, 'coins', p_coins, 'kind', v_kind, 'balance', v_bal - p_coins);
end;
$$;

-- ------------------------------------------------------------ add / move
-- A country admin adds to one of THEIR sub admins; a global admin to any.
create or replace function public.create_country_agency(p_name text, p_sub_admin uuid, p_country text default 'India')
returns public.agencies
language plpgsql security definer set search_path = public
as $$
declare
  v_role public.staff_role := public.current_staff_role();
  v_row public.agencies;
begin
  if v_role is null or v_role not in ('country_admin', 'global_admin') then
    raise exception 'Only a global or country admin can add an agency here';
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
    values (trim(p_name), coalesce(nullif(trim(p_country), ''), 'India'), 'pending', p_sub_admin)
    returning * into v_row;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'agency.create', v_row.name, 'info');
  return v_row;
end;
$$;

create or replace function public.country_transfer_agency(p_agency_id uuid, p_to_sub_admin uuid)
returns public.agencies
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.agencies;
  v_old uuid;
begin
  perform public._assert_country_actor();
  if not public.in_country_scope_agency(p_agency_id) then
    raise exception 'That agency is not under any of your sub admins';
  end if;
  if not (public.is_global_scope() or public.owns_sub_admin(p_to_sub_admin)) then
    raise exception 'The receiving sub admin must be one of yours';
  end if;
  if not exists (select 1 from public.staff_roles where user_id = p_to_sub_admin and role = 'sub_admin') then
    raise exception 'The receiving account is not a sub admin';
  end if;

  select sub_admin_id into v_old from public.agencies where id = p_agency_id;
  if v_old is not distinct from p_to_sub_admin then
    raise exception 'That sub admin already owns this agency';
  end if;

  update public.agencies set sub_admin_id = p_to_sub_admin, updated_at = now()
   where id = p_agency_id returning * into v_row;

  -- a legacy sub admin fixed to this agency via staff_roles.agency_id would
  -- otherwise keep managing it (manages_agency's first branch)
  update public.staff_roles set agency_id = null
   where role = 'sub_admin' and agency_id = p_agency_id and user_id <> p_to_sub_admin;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'agency.transfer', v_row.name, 'warning');
  return v_row;
end;
$$;

create or replace function public.transfer_sub_admin(p_sub_admin uuid, p_to_country_admin uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_country_actor();
  if not (public.is_global_scope() or public.owns_sub_admin(p_sub_admin)) then
    raise exception 'That sub admin is not one of yours';
  end if;
  if not exists (select 1 from public.staff_roles where user_id = p_sub_admin and role = 'sub_admin') then
    raise exception 'That account is not a sub admin';
  end if;
  if not exists (select 1 from public.staff_roles where user_id = p_to_country_admin and role = 'country_admin') then
    raise exception 'The receiving account is not a country admin';
  end if;

  update public.staff_roles set country_admin_id = p_to_country_admin where user_id = p_sub_admin;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'sub_admin.transfer', p_sub_admin::text, 'warning');
end;
$$;
