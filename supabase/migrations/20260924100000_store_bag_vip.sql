-- Store / My Bag / VIP — the biggest remaining piece from the MS Live
-- reference batch. Rey said to use my own judgment rather than wait on
-- exact pricing, so: catalog items are MY OWN placeholder design (emoji
-- stand-ins for real artwork, prices picked to feel roughly tiered), all
-- retunable later via plain SQL on store_items — no code redeploy needed,
-- same reasoning as level_thresholds/gifts/coin_packages already being
-- DB-driven catalogs in this schema.
--
-- Ownership model: a "purchase" grants N days of access from now
-- (extending if you already own an unexpired copy), not real recurring
-- auto-billing — matches the reference Bag screenshot showing a plain
-- "Exp: 25/8/2028" date on an owned item, not a subscription manager.
create table public.store_items (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in ('frame', 'vip', 'entry_effect', 'vehicle')),
  name text not null,
  emoji text not null,
  price_coins integer not null check (price_coins > 0),
  duration_days integer not null check (duration_days > 0),
  status text not null default 'active' check (status in ('active', 'inactive')),
  sort_order integer not null default 0
);

alter table public.store_items enable row level security;
create policy "Active store items are public" on public.store_items
  for select using (true);

insert into public.store_items (category, name, emoji, price_coins, duration_days, sort_order) values
  ('frame', 'Gold Ring', '🟡', 500, 7, 1),
  ('frame', 'Fire Ring', '🔥', 1500, 7, 2),
  ('frame', 'Diamond Ring', '💎', 2000, 7, 3),
  ('vip', 'VIP Bronze', '🥉', 5000, 30, 1),
  ('vip', 'VIP Silver', '🥈', 12000, 30, 2),
  ('vip', 'VIP Gold', '🥇', 25000, 30, 3),
  ('entry_effect', 'Sparkle Entry', '✨', 3000, 7, 1),
  ('entry_effect', 'Fire Entry', '🔥', 5000, 7, 2),
  ('vehicle', 'Motorcycle', '🏍️', 8000, 7, 1),
  ('vehicle', 'Sports Car', '🚗', 15000, 7, 2);

-- Ownership + equip state — publicly readable (mirrors user_badges'
-- "earned badges are publicly viewable"), since a frame/VIP tag is
-- cosmetic status meant to be seen by others, not private.
create table public.user_items (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  item_id uuid not null references public.store_items(id) on delete cascade,
  purchased_at timestamptz not null default now(),
  expires_at timestamptz not null,
  equipped boolean not null default false
);

alter table public.user_items enable row level security;
create policy "Owned items are public" on public.user_items for select using (true);

create index user_items_profile_id_idx on public.user_items(profile_id);

-- Store purchases are a new wallet_ledger kind alongside the existing
-- purchase/gift_sent/gift_received/grant/withdrawal/transfer_in/transfer_out.
alter table public.wallet_ledger drop constraint wallet_ledger_kind_check;
alter table public.wallet_ledger add constraint wallet_ledger_kind_check
  check (kind in ('purchase', 'gift_sent', 'gift_received', 'grant', 'withdrawal',
                   'transfer_in', 'transfer_out', 'store_purchase'));

create function public.purchase_store_item(p_item_id uuid)
returns public.user_items
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_item public.store_items%rowtype;
  v_existing public.user_items%rowtype;
  v_row public.user_items;
begin
  if v_me is null then
    raise exception 'Must be signed in to purchase';
  end if;

  select * into v_item from public.store_items where id = p_item_id and status = 'active';
  if not found then
    raise exception 'Item not found';
  end if;

  if (select coins from public.wallets where profile_id = v_me) < v_item.price_coins then
    raise exception 'Insufficient coins';
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (v_me, 'store_purchase', 'coins', -v_item.price_coins, 'store_items',
            'Purchased ' || v_item.name);

  -- Extend from the current expiry if you already own an unexpired copy,
  -- otherwise start fresh from now — same "top-up, don't waste time
  -- already paid for" logic a subscription renewal would have.
  select * into v_existing from public.user_items
    where profile_id = v_me and item_id = p_item_id and expires_at > now();

  if found then
    update public.user_items
      set expires_at = expires_at + make_interval(days => v_item.duration_days)
      where id = v_existing.id
      returning * into v_row;
  else
    insert into public.user_items (profile_id, item_id, expires_at, equipped)
      values (v_me, p_item_id, now() + make_interval(days => v_item.duration_days),
              v_item.category = 'vip')
      returning * into v_row;
  end if;

  return v_row;
end;
$$;

-- Frames/entry effects/vehicles are pick-one-per-category cosmetics (only
-- one equipped at a time); VIP is auto-equipped on purchase above since
-- it's a status you either have active or don't, not a choice among many.
create function public.set_item_equipped(p_item_id uuid, p_equipped boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_category text;
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  if not exists (
    select 1 from public.user_items
    where profile_id = v_me and item_id = p_item_id and expires_at > now()
  ) then
    raise exception 'You do not own an active copy of this item';
  end if;

  if p_equipped then
    select category into v_category from public.store_items where id = p_item_id;
    update public.user_items set equipped = false
      where profile_id = v_me and equipped = true
        and item_id in (select id from public.store_items where category = v_category);
  end if;

  update public.user_items set equipped = p_equipped
    where profile_id = v_me and item_id = p_item_id;
end;
$$;
