-- The virtual economy. Every balance-affecting event is a row in
-- wallet_ledger; wallets.coins/diamonds is a running total maintained by a
-- single trigger on that table. Nothing else is allowed to touch wallets
-- directly — not even the owning user — which is what makes the balance
-- server-authoritative instead of a client-side number.

create table public.gifts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  emoji text not null,
  price_coins integer not null check (price_coins > 0),
  category text not null default 'basic' check (category in ('basic', 'luxury', 'vehicle', 'special')),
  has_effect boolean not null default false,
  status text not null default 'active' check (status in ('active', 'inactive')),
  sort_order integer not null default 0
);

create table public.coin_packages (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  coins integer not null check (coins > 0),
  bonus_coins integer not null default 0,
  price_inr numeric(10, 2) not null,
  platform text not null default 'all' check (platform in ('all', 'android', 'ios')),
  status text not null default 'active' check (status in ('active', 'inactive')),
  sort_order integer not null default 0
);

alter table public.gifts enable row level security;
alter table public.coin_packages enable row level security;

create policy "Active gifts are public" on public.gifts for select using (status = 'active' or public.is_admin_or_above());
create policy "Admins manage gifts" on public.gifts for insert with check (public.is_admin_or_above());
create policy "Admins update gifts" on public.gifts for update using (public.is_admin_or_above());
create policy "Admins delete gifts" on public.gifts for delete using (public.is_admin_or_above());

create policy "Active packages are public" on public.coin_packages for select using (status = 'active' or public.is_admin_or_above());
create policy "Admins manage packages" on public.coin_packages for insert with check (public.is_admin_or_above());
create policy "Admins update packages" on public.coin_packages for update using (public.is_admin_or_above());
create policy "Admins delete packages" on public.coin_packages for delete using (public.is_admin_or_above());

-- --------------------------------------------------------------- wallets
create table public.wallets (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  coins bigint not null default 0 check (coins >= 0),
  diamonds bigint not null default 0 check (diamonds >= 0),
  updated_at timestamptz not null default now()
);

alter table public.wallets enable row level security;

create policy "Owners and staff view a wallet"
  on public.wallets for select using (profile_id = auth.uid() or public.is_admin_or_above());
-- No insert/update/delete policy for authenticated at all: only the
-- wallet_ledger trigger (which runs as the table owner) can change a balance.
revoke insert, update, delete on public.wallets from authenticated;

create function public.create_wallet_for_profile()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.wallets (profile_id) values (new.id);
  return new;
end;
$$;

create trigger profiles_create_wallet
  after insert on public.profiles
  for each row execute function public.create_wallet_for_profile();

-- ------------------------------------------------------------ wallet ledger
create table public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id),
  kind text not null check (kind in ('purchase', 'gift_sent', 'gift_received', 'grant', 'withdrawal')),
  currency text not null check (currency in ('coins', 'diamonds')),
  amount bigint not null,
  reference_table text,
  reference_id uuid,
  note text,
  created_at timestamptz not null default now()
);

create index wallet_ledger_profile_idx on public.wallet_ledger (profile_id, created_at desc);

alter table public.wallet_ledger enable row level security;

create policy "Owners and staff view ledger entries"
  on public.wallet_ledger for select using (profile_id = auth.uid() or public.is_admin_or_above());
-- No client insert policy: rows are only ever written by the SECURITY DEFINER
-- functions below (send_gift, request_withdrawal) or by service-role code
-- (coin purchase webhook, admin coin grants).

create function public.apply_wallet_ledger_entry()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.currency = 'coins' then
    update public.wallets set coins = coins + new.amount, updated_at = now() where profile_id = new.profile_id;
  else
    update public.wallets set diamonds = diamonds + new.amount, updated_at = now() where profile_id = new.profile_id;
  end if;
  return new;
end;
$$;

create trigger wallet_ledger_after_insert
  after insert on public.wallet_ledger
  for each row execute function public.apply_wallet_ledger_entry();

-- ---------------------------------------------------------- coin purchases
-- Written only by the payment-webhook Edge Function (service role) once a
-- real payment is confirmed — never directly by the client.
create table public.coin_purchases (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id),
  package_id uuid references public.coin_packages (id),
  coins_credited integer not null,
  amount_inr numeric(10, 2) not null,
  payment_method text,
  payment_reference text,
  status text not null default 'pending' check (status in ('pending', 'success', 'failed', 'refunded')),
  created_at timestamptz not null default now()
);

alter table public.coin_purchases enable row level security;

create policy "Owners and staff view purchases"
  on public.coin_purchases for select using (profile_id = auth.uid() or public.is_admin_or_above());

create function public.handle_coin_purchase_success()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'success' and (old.status is distinct from 'success') then
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (new.profile_id, 'purchase', 'coins', new.coins_credited, 'coin_purchases', new.id, 'Coin package purchase');
  end if;
  return new;
end;
$$;

create trigger coin_purchases_after_update
  after update on public.coin_purchases
  for each row execute function public.handle_coin_purchase_success();

-- ------------------------------------------------------------- gift sending
create table public.gift_transactions (
  id uuid primary key default gen_random_uuid(),
  live_stream_id uuid references public.live_streams (id),
  sender_id uuid not null references public.profiles (id),
  receiver_id uuid not null references public.profiles (id),
  gift_id uuid not null references public.gifts (id),
  coins integer not null,
  created_at timestamptz not null default now()
);

create index gift_transactions_receiver_idx on public.gift_transactions (receiver_id, created_at desc);

alter table public.gift_transactions enable row level security;

create policy "Sender, receiver, and staff see a gift transaction"
  on public.gift_transactions for select
  using (sender_id = auth.uid() or receiver_id = auth.uid() or public.is_admin_or_above());
-- No insert policy: only send_gift() (security definer) writes here.

-- Atomically debits the sender's coins, credits the receiver's diamonds,
-- logs the gift, and bumps the stream's running gift total. Raises (and
-- rolls back everything) if the sender can't afford it.
create function public.send_gift(p_gift_id uuid, p_receiver_id uuid, p_live_stream_id uuid default null)
returns public.gift_transactions
language plpgsql security definer set search_path = public
as $$
declare
  v_price integer;
  v_sender uuid := auth.uid();
  v_tx public.gift_transactions;
begin
  if v_sender is null then
    raise exception 'Must be signed in to send a gift';
  end if;

  select price_coins into v_price from public.gifts where id = p_gift_id and status = 'active';
  if v_price is null then
    raise exception 'Unknown or inactive gift';
  end if;

  if (select coins from public.wallets where profile_id = v_sender) < v_price then
    raise exception 'Insufficient coins';
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (v_sender, 'gift_sent', 'coins', -v_price, 'gift_transactions', 'Gift sent');
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (p_receiver_id, 'gift_received', 'diamonds', v_price, 'gift_transactions', 'Gift received');

  insert into public.gift_transactions (live_stream_id, sender_id, receiver_id, gift_id, coins)
    values (p_live_stream_id, v_sender, p_receiver_id, p_gift_id, v_price)
    returning * into v_tx;

  if p_live_stream_id is not null then
    update public.live_streams set gift_coin_total = gift_coin_total + v_price where id = p_live_stream_id;
  end if;

  return v_tx;
end;
$$;

-- ------------------------------------------------------------- coin grants
-- Admin-initiated manual transfers (bonuses, corrections, event payouts).
create table public.coin_grants (
  id uuid primary key default gen_random_uuid(),
  granted_to uuid not null references public.profiles (id),
  granted_by uuid not null references public.profiles (id),
  coins integer not null,
  note text,
  created_at timestamptz not null default now()
);

alter table public.coin_grants enable row level security;

create policy "Recipient and staff see a grant"
  on public.coin_grants for select using (granted_to = auth.uid() or public.is_admin_or_above());
create policy "Admins issue coin grants"
  on public.coin_grants for insert with check (public.is_admin_or_above() and granted_by = auth.uid());

create function public.handle_coin_grant()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (new.granted_to, 'grant', 'coins', new.coins, 'coin_grants', new.id, coalesce(new.note, 'Admin grant'));
  return new;
end;
$$;

create trigger coin_grants_after_insert
  after insert on public.coin_grants
  for each row execute function public.handle_coin_grant();

-- --------------------------------------------------------------- withdrawals
create table public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id),
  diamonds integer not null check (diamonds > 0),
  amount_inr numeric(10, 2),
  status text not null default 'pending' check (status in ('pending', 'processing', 'paid', 'rejected')),
  requested_at timestamptz not null default now(),
  processed_at timestamptz,
  processed_by uuid references public.profiles (id)
);

alter table public.withdrawals enable row level security;

create policy "Owners and staff see withdrawals"
  on public.withdrawals for select using (profile_id = auth.uid() or public.is_admin_or_above());
create policy "Admins process withdrawals"
  on public.withdrawals for update using (public.is_admin_or_above());

-- Escrows the diamonds immediately (debited on request, refunded if rejected
-- by request_withdrawal_decision) so a user can't request the same balance twice.
create function public.request_withdrawal(p_diamonds integer)
returns public.withdrawals
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_row public.withdrawals;
begin
  if v_user is null then
    raise exception 'Must be signed in to request a withdrawal';
  end if;
  if (select diamonds from public.wallets where profile_id = v_user) < p_diamonds then
    raise exception 'Insufficient diamonds';
  end if;

  insert into public.withdrawals (profile_id, diamonds) values (v_user, p_diamonds) returning * into v_row;
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (v_user, 'withdrawal', 'diamonds', -p_diamonds, 'withdrawals', v_row.id, 'Withdrawal requested');

  return v_row;
end;
$$;

create function public.decide_withdrawal(p_withdrawal_id uuid, p_approve boolean)
returns public.withdrawals
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.withdrawals;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can decide withdrawals';
  end if;

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
$$;

-- ---------------------------------------------------------------- salary
create table public.salary_payments (
  id uuid primary key default gen_random_uuid(),
  payee_id uuid not null references public.profiles (id),
  role text not null check (role in ('host', 'sub_admin', 'agency_manager')),
  agency_id uuid references public.agencies (id),
  period text not null,
  base_amount numeric(10, 2) not null default 0,
  bonus_amount numeric(10, 2) not null default 0,
  deductions numeric(10, 2) not null default 0,
  net_amount numeric(10, 2) generated always as (base_amount + bonus_amount - deductions) stored,
  status text not null default 'processing' check (status in ('processing', 'paid', 'on_hold')),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (payee_id, period)
);

alter table public.salary_payments enable row level security;

create policy "Payee and staff see salary records"
  on public.salary_payments for select
  using (payee_id = auth.uid() or public.manages_agency(agency_id));
create policy "Staff manage salary in their scope"
  on public.salary_payments for insert with check (public.manages_agency(agency_id));
create policy "Staff update salary in their scope"
  on public.salary_payments for update using (public.manages_agency(agency_id));
