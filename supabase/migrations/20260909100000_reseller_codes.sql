-- Selling coins to other users (becoming a coin reseller/agent) is gated the
-- same way as going live: an agency/admin issues a reseller code with an
-- expiry chosen at generation; the user redeems it for a time-limited grant.
-- Structurally a mirror of host_codes / host_grants.

create table public.reseller_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  agency_id uuid references public.agencies (id) on delete set null,
  created_by uuid references public.profiles (id),
  label text,
  max_uses integer not null default 1 check (max_uses between 1 and 500),
  used_count integer not null default 0,
  expires_at timestamptz not null,
  status text not null default 'active' check (status in ('active', 'banned')),
  created_at timestamptz not null default now()
);

create index reseller_codes_agency_idx on public.reseller_codes (agency_id, created_at desc);
alter table public.reseller_codes enable row level security;

create policy "Staff see reseller codes they manage"
  on public.reseller_codes for select
  using (public.is_admin_or_above() or public.manages_agency(agency_id));

create table public.reseller_grants (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  code_id uuid references public.reseller_codes (id) on delete set null,
  agency_id uuid references public.agencies (id) on delete set null,
  granted_by uuid references public.profiles (id),
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  status text not null default 'active'
    check (status in ('active', 'revoked', 'banned')),
  ban_reason text,
  created_at timestamptz not null default now()
);

create index reseller_grants_profile_idx on public.reseller_grants (profile_id, status);
create index reseller_grants_agency_idx on public.reseller_grants (agency_id, granted_at desc);
alter table public.reseller_grants enable row level security;

create policy "Owners and managing staff see reseller grants"
  on public.reseller_grants for select
  using (
    profile_id = auth.uid()
    or public.is_admin_or_above()
    or public.manages_agency(agency_id)
  );

-- ─────────────────────────────────────────────── coin transfers (audit log)
do $$
declare c text;
begin
  select conname into c from pg_constraint
  where conrelid = 'public.wallet_ledger'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%kind%purchase%';
  if c is not null then
    execute format('alter table public.wallet_ledger drop constraint %I', c);
  end if;
end $$;

alter table public.wallet_ledger
  add constraint wallet_ledger_kind_check
  check (kind in ('purchase', 'gift_sent', 'gift_received', 'grant',
                  'withdrawal', 'transfer_in', 'transfer_out'));

create table public.coin_transfers (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles (id),
  recipient_id uuid not null references public.profiles (id),
  coins integer not null check (coins > 0),
  note text,
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);

create index coin_transfers_sender_idx on public.coin_transfers (sender_id, created_at desc);
create index coin_transfers_recipient_idx on public.coin_transfers (recipient_id, created_at desc);
alter table public.coin_transfers enable row level security;

create policy "Participants and staff see coin transfers"
  on public.coin_transfers for select
  using (
    sender_id = auth.uid() or recipient_id = auth.uid()
    or public.is_admin_or_above()
  );

-- ─────────────────────────────────────────────── helpers + RPCs
create function public.has_active_reseller_access(p_uid uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select
    exists (select 1 from public.staff_roles where user_id = p_uid)
    or exists (
      select 1 from public.reseller_grants
      where profile_id = p_uid and status = 'active'
        and (expires_at is null or expires_at > now())
    );
$$;
grant execute on function public.has_active_reseller_access(uuid) to authenticated;

create function public.generate_reseller_code(
  p_expires_at timestamptz,
  p_label text default null,
  p_max_uses integer default 1
) returns public.reseller_codes
language plpgsql security definer set search_path = public
as $$
declare
  v_code text;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_row public.reseller_codes;
  i integer;
begin
  if not public.is_staff() then
    raise exception 'Only staff can generate reseller codes';
  end if;
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
$$;
grant execute on function public.generate_reseller_code(timestamptz, text, integer) to authenticated;

create function public.redeem_reseller_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_code public.reseller_codes;
  v_existing public.reseller_grants;
begin
  if v_me is null then raise exception 'Sign in first'; end if;

  select * into v_existing from public.reseller_grants
  where profile_id = v_me and status = 'active'
    and (expires_at is null or expires_at > now())
  order by expires_at desc nulls first limit 1;
  if v_existing.id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'expires_at', v_existing.expires_at);
  end if;

  select * into v_code from public.reseller_codes where upper(code) = upper(trim(p_code));
  if v_code.id is null then raise exception 'That code is not valid'; end if;
  if v_code.status = 'banned' then raise exception 'That code has been disabled'; end if;
  if v_code.expires_at <= now() then raise exception 'That code has expired'; end if;
  if v_code.used_count >= v_code.max_uses then raise exception 'That code has already been used'; end if;

  insert into public.reseller_grants (profile_id, code_id, agency_id, granted_by, expires_at)
  values (v_me, v_code.id, v_code.agency_id, v_code.created_by, v_code.expires_at);
  update public.reseller_codes set used_count = used_count + 1 where id = v_code.id;

  return jsonb_build_object('ok', true, 'already', false, 'expires_at', v_code.expires_at);
end;
$$;
grant execute on function public.redeem_reseller_code(text) to authenticated;

create function public.my_reseller_access()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_grant public.reseller_grants;
begin
  if v_me is null then return jsonb_build_object('has_access', false); end if;
  if exists (select 1 from public.staff_roles where user_id = v_me) then
    return jsonb_build_object('has_access', true, 'staff', true);
  end if;
  select * into v_grant from public.reseller_grants
  where profile_id = v_me and status = 'active'
    and (expires_at is null or expires_at > now())
  order by expires_at desc nulls first limit 1;
  return jsonb_build_object(
    'has_access', v_grant.id is not null,
    'expires_at', v_grant.expires_at,
    'banned', exists (select 1 from public.reseller_grants
                      where profile_id = v_me and status = 'banned')
  );
end;
$$;
grant execute on function public.my_reseller_access() to authenticated;

create function public.set_reseller_code_status(p_code_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_code public.reseller_codes;
begin
  select * into v_code from public.reseller_codes where id = p_code_id;
  if v_code.id is null then raise exception 'Code not found'; end if;
  if not (public.is_admin_or_above() or public.manages_agency(v_code.agency_id)) then
    raise exception 'Not allowed to manage this code';
  end if;
  if p_status not in ('active', 'banned') then raise exception 'status must be active or banned'; end if;
  update public.reseller_codes set status = p_status where id = p_code_id;
  if p_status = 'banned' then
    update public.reseller_grants set status = 'banned', ban_reason = 'code disabled'
    where code_id = p_code_id and status = 'active';
  end if;
end;
$$;
grant execute on function public.set_reseller_code_status(uuid, text) to authenticated;

create function public.set_reseller_grant_status(
  p_grant_id uuid, p_status text, p_reason text default null
) returns void language plpgsql security definer set search_path = public
as $$
declare v_grant public.reseller_grants;
begin
  select * into v_grant from public.reseller_grants where id = p_grant_id;
  if v_grant.id is null then raise exception 'Grant not found'; end if;
  if not (public.is_admin_or_above() or public.manages_agency(v_grant.agency_id)) then
    raise exception 'Not allowed to manage this grant';
  end if;
  if p_status not in ('active', 'revoked', 'banned') then raise exception 'invalid status'; end if;
  update public.reseller_grants
    set status = p_status,
        ban_reason = case when p_status = 'active' then null else nullif(trim(p_reason), '') end
  where id = p_grant_id;
end;
$$;
grant execute on function public.set_reseller_grant_status(uuid, text, text) to authenticated;

-- ─────────────────────────────────────────────── the actual coin sale
create function public.resell_coins(p_recipient text, p_coins integer, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_to uuid;
  v_bal bigint;
  v_note text := nullif(trim(p_note), '');
begin
  if v_me is null then raise exception 'Sign in first'; end if;
  if not public.has_active_reseller_access(v_me) then
    raise exception 'You are not an approved coin reseller';
  end if;
  if p_coins is null or p_coins <= 0 then raise exception 'Enter a valid amount'; end if;

  select id into v_to from public.profiles
    where lower(username) = lower(replace(trim(p_recipient), '@', ''));
  if v_to is null then raise exception 'No user matches "%"', p_recipient; end if;
  if v_to = v_me then raise exception 'You cannot sell coins to yourself'; end if;

  select coins into v_bal from public.wallets where profile_id = v_me;
  if coalesce(v_bal, 0) < p_coins then raise exception 'Not enough coins in your balance'; end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
    values (v_me, 'transfer_out', 'coins', -p_coins, coalesce(v_note, 'Coin sale'));
  insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
    values (v_to, 'transfer_in', 'coins', p_coins, 'Coins from a reseller');
  insert into public.coin_transfers (sender_id, recipient_id, coins, note)
    values (v_me, v_to, p_coins, v_note);

  return jsonb_build_object('ok', true, 'coins', p_coins);
end;
$$;
grant execute on function public.resell_coins(text, integer, text) to authenticated;
