-- Hierarchy stage 1 (Sub Admin): a sub admin owns MANY agencies, and coins
-- cascade downward wallet-to-wallet (Sub Admin -> Agency -> User).
--
-- Everything is additive:
--   * agencies gains sub_admin_id. Existing sub_admins are backfilled as the
--     owner of the one agency they were already scoped to, so nothing they
--     could reach yesterday is lost.
--   * manages_agency() gains one extra OR branch (owned agencies); the old
--     "current_agency_id() = target" branch is kept verbatim.
--   * coin_transfers (the existing wallet-to-wallet audit log used by
--     resell_coins) gains recipient_kind + agency_id so per-direction
--     history (to Agency / to User) is a filter, not a new table.
--   * Balances live in wallets.coins for every level — staff are profiles
--     with wallets — so the existing treasury distribute_coins() (audience
--     'role' = sub_admin / agency) already funds the top of this chain.

-- ------------------------------------------------------------ ownership
alter table public.agencies
  add column sub_admin_id uuid references public.profiles (id) on delete set null;

create index agencies_sub_admin_idx on public.agencies (sub_admin_id);

-- Backfill: an existing sub_admin owns the agency their staff_roles row points at.
update public.agencies a
   set sub_admin_id = s.user_id
  from (
    select distinct on (agency_id) agency_id, user_id
      from public.staff_roles
     where role = 'sub_admin' and agency_id is not null
     order by agency_id, created_at
  ) s
 where a.id = s.agency_id and a.sub_admin_id is null;

-- A sub_admin may now own several agencies (or none yet), so it no longer
-- needs a single fixed agency_id. agency_manager stays tied to exactly one.
alter table public.staff_roles drop constraint agency_role_requires_agency;
alter table public.staff_roles
  add constraint agency_role_requires_agency
  check (role <> 'agency_manager' or agency_id is not null);

-- Keep the existing "grant a sub_admin an agency" flow producing ownership.
create function public.sync_sub_admin_agency_owner()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.role = 'sub_admin' and new.agency_id is not null then
    update public.agencies set sub_admin_id = new.user_id
     where id = new.agency_id and sub_admin_id is null;
  end if;
  return new;
end;
$$;

create trigger staff_roles_sync_sub_admin_agency
  after insert or update of role, agency_id on public.staff_roles
  for each row execute function public.sync_sub_admin_agency_owner();

-- security definer so it can be used inside RLS policies without recursing.
create function public.owns_agency(p_agency_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce(
    exists (select 1 from public.agencies
             where id = p_agency_id and sub_admin_id = auth.uid()),
    false);
$$;
revoke execute on function public.owns_agency(uuid) from public, anon;
grant execute on function public.owns_agency(uuid) to authenticated;

-- Same null-safe shape as 20260930110000; one added branch.
create or replace function public.manages_agency(target_agency_id uuid)
returns boolean language sql stable
as $$
  select coalesce(
    public.is_admin_or_above()
      or (public.current_staff_role() in ('agency_manager', 'sub_admin')
          and public.current_agency_id() = target_agency_id)
      or (public.current_staff_role() = 'sub_admin'
          and public.owns_agency(target_agency_id)),
    false
  );
$$;

-- A sub admin must see the staff (managers) of every agency they own, not
-- just the one in their own staff_roles row.
create policy "Sub admins see staff of agencies they own"
  on public.staff_roles for select
  using (agency_id is not null and public.owns_agency(agency_id));

-- ------------------------------------------------------------ add an agency
-- Creates a PENDING agency owned by the caller; a platform admin still
-- approves it and sets commission (agencies UPDATE stays admin-only).
create function public.create_sub_admin_agency(p_name text, p_country text default 'India')
returns public.agencies
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.agencies;
begin
  if public.current_staff_role() is distinct from 'sub_admin' then
    raise exception 'Only a sub admin can add an agency here';
  end if;
  if nullif(trim(p_name), '') is null then
    raise exception 'Agency name is required';
  end if;

  insert into public.agencies (name, country, status, sub_admin_id)
    values (trim(p_name), coalesce(nullif(trim(p_country), ''), 'India'), 'pending', auth.uid())
    returning * into v_row;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'agency.create', v_row.name, 'info');

  return v_row;
end;
$$;
revoke execute on function public.create_sub_admin_agency(text, text) from public, anon;
grant execute on function public.create_sub_admin_agency(text, text) to authenticated;

-- ------------------------------------------------------------ coin cascade
alter table public.coin_transfers
  add column recipient_kind text not null default 'user'
    check (recipient_kind in ('user', 'agency', 'sub_admin')),
  add column agency_id uuid references public.agencies (id) on delete set null;

create index coin_transfers_agency_idx on public.coin_transfers (agency_id, created_at desc);
create index coin_transfers_kind_idx on public.coin_transfers (recipient_kind, created_at desc);

drop policy "Participants and staff see coin transfers" on public.coin_transfers;
create policy "Participants, owners and staff see coin transfers"
  on public.coin_transfers for select
  using (
    sender_id = auth.uid() or recipient_id = auth.uid()
    or public.is_admin_or_above()
    or (agency_id is not null and public.manages_agency(agency_id))
  );

-- Moves coins from the caller's wallet to a recipient one level down.
--   sub_admin      -> agency manager of an agency they OWN, or any plain user
--   agency_manager -> any plain user
-- Platform admins are funded from the treasury (distribute_coins), not here.
create function public.transfer_coins_down(p_recipient uuid, p_coins bigint, p_note text default null)
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
  if v_role is null or v_role not in ('sub_admin', 'agency_manager') then
    raise exception 'Only a sub admin or agency can transfer coins from this panel';
  end if;
  if p_coins is null or p_coins <= 0 then raise exception 'Enter a valid amount'; end if;
  if p_coins > 2147483647 then raise exception 'Amount is too large'; end if;
  if p_recipient is null or p_recipient = v_me then raise exception 'Pick someone else as the recipient'; end if;
  if not exists (select 1 from public.profiles where id = p_recipient) then
    raise exception 'Recipient not found';
  end if;

  select role, agency_id into v_rrole, v_ragency from public.staff_roles where user_id = p_recipient;

  if v_rrole in ('super_admin', 'admin') then
    raise exception 'Coins cannot be sent up to platform admins';
  elsif v_rrole = 'sub_admin' then
    raise exception 'Coins cannot be sent sideways to another sub admin';
  elsif v_rrole = 'agency_manager' then
    if v_role <> 'sub_admin' then
      raise exception 'An agency can only send coins to users';
    end if;
    if not public.owns_agency(v_ragency) then
      raise exception 'That agency is not one of yours';
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
revoke execute on function public.transfer_coins_down(uuid, bigint, text) from public, anon;
grant execute on function public.transfer_coins_down(uuid, bigint, text) to authenticated;
