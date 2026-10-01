-- 1. Master (role 'admin') can now wallet-to-wallet transfer coins down to a
--    Global Admin, the same way a Global Admin already transfers down to a
--    Country Admin — Master was simply never added as a sender, and
--    'global_admin' was blocked as a recipient entirely (nobody above it
--    could ever reach it this way). Re-emitting transfer_coins_down's body
--    verbatim (from 20260930160000_global_admin_scope.sql) with 'admin'
--    added as a sender and a new 'global_admin' recipient branch.
alter table public.coin_transfers drop constraint coin_transfers_recipient_kind_check;
alter table public.coin_transfers add constraint coin_transfers_recipient_kind_check
  check (recipient_kind in ('user', 'agency', 'sub_admin', 'country_admin', 'global_admin'));

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
  if v_role is null or v_role not in ('admin', 'global_admin', 'country_admin', 'sub_admin', 'agency_manager') then
    raise exception 'Only Master, a global admin, country admin, sub admin or agency can transfer coins from this panel';
  end if;
  if p_coins is null or p_coins <= 0 then raise exception 'Enter a valid amount'; end if;
  if p_coins > 2147483647 then raise exception 'Amount is too large'; end if;
  if p_recipient is null or p_recipient = v_me then raise exception 'Pick someone else as the recipient'; end if;
  if not exists (select 1 from public.profiles where id = p_recipient) then
    raise exception 'Recipient not found';
  end if;

  select role, agency_id into v_rrole, v_ragency from public.staff_roles where user_id = p_recipient;

  if v_rrole in ('super_admin', 'admin') then
    raise exception 'Coins cannot be sent up or sideways to a platform admin';
  elsif v_rrole = 'global_admin' then
    if v_role <> 'admin' then
      raise exception 'Coins cannot be sent up or sideways to a global admin';
    end if;
    v_kind := 'global_admin';
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

-- 2. Super Admin's own Coin Treasury "Distribute" may only target Master
--    (role 'admin') accounts — matching the same Super-Admin-only-touches-
--    Master boundary as account creation (20261001100000). Every other
--    caller of distribute_coins (Master itself, or an explicitly
--    coin_minters-listed account) is unaffected. Re-emitting the body
--    verbatim (from 20260930210000) with the one added check.
create or replace function public.distribute_coins(
  p_per_recipient bigint,
  p_audience text,
  p_role text default null,
  p_recipient_ids uuid[] default null,
  p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_ids uuid[];
  v_count integer;
  v_total bigint;
  v_balance bigint;
begin
  if not public.can_mint_coins() then
    raise exception 'Not allowed to distribute coins';
  end if;
  if public.current_staff_role() = 'super_admin' and not (p_audience = 'role' and p_role = 'admin') then
    raise exception 'A Super Admin may only distribute coins to Master accounts';
  end if;
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
        when 'host'          then p.is_host
        when 'agency'        then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'agency_manager')
        when 'sub_admin'     then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'sub_admin')
        when 'country_admin' then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'country_admin')
        when 'global_admin'  then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'global_admin')
        when 'admin'         then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'admin')
        when 'staff'         then exists (select 1 from public.staff_roles s where s.user_id = p.id)
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

  insert into public.wallets (profile_id)
    select unnest(v_ids) on conflict (profile_id) do nothing;

  insert into public.coin_grants (granted_to, granted_by, coins, note)
    select unnest(v_ids), auth.uid(), p_per_recipient::integer,
           coalesce(nullif(trim(p_note), ''), 'Treasury distribution');

  update public.coin_treasury
    set distributed_total = distributed_total + v_total,
        updated_at = now(),
        updated_by = auth.uid()
    where id = true;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'treasury.distribute', p_audience || coalesce(':' || p_role, '') || ' x' || v_count, 'info');

  return jsonb_build_object('recipients', v_count, 'total', v_total,
    'balance', v_balance - v_total);
end;
$$;
