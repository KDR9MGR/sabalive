-- Super Admin coin treasury. "Generating" coins mints them into a single
-- treasury balance (unlimited — this is the platform's own supply, not a
-- purchase); distributing draws that balance down and credits recipient
-- wallets through the existing coin_grants -> wallet_ledger machinery.
-- Who may mint/distribute is a Super-Admin-managed allow-list on top of
-- super_admin itself.

-- ------------------------------------------------------------ treasury (singleton)
create table public.coin_treasury (
  id boolean primary key default true check (id),
  minted_total      bigint not null default 0 check (minted_total >= 0),
  distributed_total bigint not null default 0 check (distributed_total >= 0),
  balance bigint generated always as (minted_total - distributed_total) stored,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id),
  check (distributed_total <= minted_total)
);

insert into public.coin_treasury (id) values (true);

alter table public.coin_treasury enable row level security;
create policy "Staff read the treasury"
  on public.coin_treasury for select using (public.is_admin_or_above());
-- no insert / update / delete policy: mutated only by the RPCs below.

-- ------------------------------------------------------------ event log
create table public.coin_treasury_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check (event_type in ('mint', 'distribution')),
  coins bigint not null check (coins > 0),          -- total coins moved by this event
  per_recipient bigint,                             -- distribution only
  audience text,                                    -- distribution only: all | role:<r> | users
  recipients integer not null default 0,
  note text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index coin_treasury_events_created_idx on public.coin_treasury_events (created_at desc);

alter table public.coin_treasury_events enable row level security;
create policy "Staff read treasury events"
  on public.coin_treasury_events for select using (public.is_admin_or_above());

-- ------------------------------------------------------------ minter allow-list
create table public.coin_minters (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  added_by uuid references public.profiles (id),
  added_at timestamptz not null default now()
);

alter table public.coin_minters enable row level security;
create policy "Staff read the minter list"
  on public.coin_minters for select using (public.is_admin_or_above());
create policy "Super admins manage the minter list"
  on public.coin_minters for insert with check (public.is_super_admin());
create policy "Super admins remove minters"
  on public.coin_minters for delete using (public.is_super_admin());

create function public.can_mint_coins()
returns boolean language sql stable set search_path = public
as $$
  select public.is_super_admin()
      or exists (select 1 from public.coin_minters where profile_id = auth.uid());
$$;

-- ------------------------------------------------------------ mint
create function public.mint_coins(p_coins bigint, p_note text default null)
returns public.coin_treasury
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.coin_treasury;
begin
  if not public.can_mint_coins() then
    raise exception 'Not allowed to generate coins';
  end if;
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
$$;

revoke execute on function public.mint_coins(bigint, text) from anon;

-- ------------------------------------------------------------ distribute
-- p_audience: 'all' | 'role' | 'users'
-- p_role (when p_audience='role'): 'host' | 'agency' | 'sub_admin' | 'staff'
-- p_recipient_ids (when p_audience='users'): profile ids
create function public.distribute_coins(
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
$$;

revoke execute on function public.distribute_coins(bigint, text, text, uuid[], text) from anon;
