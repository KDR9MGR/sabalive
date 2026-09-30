-- 1. Master can distribute coins to every account at a level (Global Admin /
--    Country Admin / Sub Admin / Agency / all Users), reusing distribute_coins
--    (already used by Super Admin's Coin Treasury). Re-emitting the full body
--    verbatim (from 20260908090500_coin_treasury.sql) with two new p_role
--    branches — nothing else changes.
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

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'treasury.distribute', p_audience || coalesce(':' || p_role, '') || ' x' || v_count, 'info');

  return jsonb_build_object('recipients', v_count, 'total', v_total,
    'balance', v_balance - v_total);
end;
$$;

-- 2. A Master account (role 'admin') may now distribute treasury coins too —
--    previously only super_admin or an explicitly coin_minters-listed profile
--    could. is_admin_or_above() already covers 'admin' and 'super_admin'.
create or replace function public.can_mint_coins()
returns boolean language sql stable set search_path = public
as $$
  select public.is_admin_or_above()
      or exists (select 1 from public.coin_minters where profile_id = auth.uid());
$$;

-- 3. Pull back a coin_grants-sourced credit (from either Master's direct
--    per-user grant or a distribute_coins batch — both write coin_grants the
--    same way). Deducts from the recipient's CURRENT balance; refuses if
--    they've already spent below the granted amount, or if this grant was
--    already pulled back.
alter table public.wallet_ledger drop constraint wallet_ledger_kind_check;
alter table public.wallet_ledger add constraint wallet_ledger_kind_check
  check (kind in ('purchase', 'gift_sent', 'gift_received', 'grant', 'withdrawal', 'grant_reversal'));

create function public.pull_back_coin_grant(p_grant_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_grant public.coin_grants;
  v_balance integer;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can pull back a coin grant';
  end if;

  select * into v_grant from public.coin_grants where id = p_grant_id;
  if v_grant.id is null then
    raise exception 'Grant not found';
  end if;

  if exists (
    select 1 from public.wallet_ledger
    where reference_table = 'coin_grants' and reference_id = p_grant_id and kind = 'grant_reversal'
  ) then
    raise exception 'This grant has already been pulled back';
  end if;

  select coins into v_balance from public.wallets where profile_id = v_grant.granted_to;
  if coalesce(v_balance, 0) < v_grant.coins then
    raise exception 'Cannot pull back — the recipient only has % coins left of the % granted', coalesce(v_balance, 0), v_grant.coins;
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (v_grant.granted_to, 'grant_reversal', 'coins', -v_grant.coins, 'coin_grants', p_grant_id,
            coalesce('Pulled back: ' || v_grant.note, 'Pulled back by admin'));

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'coin_grant.pull_back', p_grant_id::text, 'warning');
end;
$$;

grant execute on function public.pull_back_coin_grant(uuid) to authenticated;

-- Accurate push wording for a pull-back, instead of the generic "grant" text.
create or replace function public.notify_wallet_ledger_entry()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_body text;
begin
  v_body := case
    when new.kind = 'grant' and new.note = 'lucky_box' then
      'Lucky Box! You earned ' || new.amount || ' ' || new.currency || ' for a great streak of live time'
    when new.kind = 'grant_reversal' then
      abs(new.amount) || ' ' || new.currency || ' were reclaimed from your wallet by an admin'
    when new.kind = 'gift_received' then 'You received a gift — +' || new.amount || ' ' || new.currency
    when new.kind = 'purchase' then 'Purchase successful — +' || new.amount || ' ' || new.currency
    when new.kind = 'grant' then 'You received ' || new.amount || ' ' || new.currency
    when new.kind = 'withdrawal' then 'Withdrawal of ' || abs(new.amount) || ' ' || new.currency || ' processed'
    else null
  end;
  if v_body is not null then
    insert into public.notifications (profile_id, kind, body)
    values (new.profile_id, case when new.note = 'lucky_box' then 'lucky_box' else 'coins_' || new.kind end, v_body);
  end if;
  return new;
end;
$$;

-- 4. Transfer Country — reassign an agency's region label. Mirrors
--    country_transfer_agency's authorization exactly (same actor/scope
--    checks), from 20260930160000_global_admin_scope.sql.
create function public.country_transfer_agency_country(p_agency_id uuid, p_country text)
returns public.agencies
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.agencies;
begin
  perform public._assert_country_actor();
  if not public.in_country_scope_agency(p_agency_id) then
    raise exception 'That agency is not under any of your sub admins';
  end if;
  if coalesce(trim(p_country), '') = '' then
    raise exception 'Country is required';
  end if;

  update public.agencies set country = trim(p_country), updated_at = now()
   where id = p_agency_id returning * into v_row;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'agency.transfer_country', v_row.name || ' -> ' || v_row.country, 'info');
  return v_row;
end;
$$;

grant execute on function public.country_transfer_agency_country(uuid, text) to authenticated;
