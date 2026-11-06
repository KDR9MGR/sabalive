-- VIP products (owner, 2026-11-06): a VIP screen in the app (a list of cards, each opening a page with its benefits, a price and a Buy button) and a panel page that creates them.
--
-- THE MODEL
--   vip_products           one card / page: name, short line, the badge picture, a coin price, a number of days, active or hidden, an order.
--                          A product IS a bundle: it lists its benefits and is bought as one thing (owner's answer: "a product is a bundle").
--   vip_product_benefits   what the product includes, each with a KIND (a short key such as 'avatar_frame', 'entry_effect', 'anti_kick' or 'custom': the list the panel
--                          offers lives in the panel and the app, not here, so a new kind needs no migration), an optional title and picture, and an optional LINK to an
--                          existing Store item (frame, entry effect, vehicle, room skin) which the buyer is given.
--   user_vip               who owns which product and until when ("N days, buying again adds the days", exactly like the Store).
--
-- WHAT BUYING DOES (owner's choice: "show + grant existing items")
--   * takes the price in coins (a store_purchase ledger row, like the Store), starts or extends the person's days on that product;
--   * gives the buyer every Store item linked to the product, until the VIP's end date (an item they already own keeps its later date), and puts it on when they have
--     nothing on in that category yet;
--   * the product's badge shows on the person's own profile while it is active (the app reads user_vip).
--   Benefits with no link (Anti-Kick, Anti-Ban, Hide Country, XP boost, Daily Check In ...) are LISTED ONLY: no rule changes. Each is switched on later, one at a time, when
--   the owner decides its rule.
--
-- WHO MAY MANAGE: Master and Super Admin (is_admin_or_above()), like the Store's item assignment. Everyone else can only read ACTIVE products and buy them.
--
-- Additive: three new tables, five new functions (new names), no existing table, function or policy is touched. Old apps never see any of it.
-- Rollback: supabase/rollbacks/20261106120000_down.sql.
set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.vip_products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 40),
  tagline text check (tagline is null or char_length(tagline) <= 120),
  badge_url text check (badge_url is null or char_length(badge_url) <= 600),
  price_coins integer not null check (price_coins > 0),
  duration_days integer not null check (duration_days between 1 and 3650),
  status text not null default 'active' check (status in ('active', 'inactive')),
  sort_order integer not null default 0,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.vip_product_benefits (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.vip_products (id) on delete cascade,
  kind text not null check (kind ~ '^[a-z][a-z0-9_]{1,39}$'),
  title text check (title is null or char_length(btrim(title)) between 1 and 40),
  image_url text check (image_url is null or char_length(image_url) <= 600),
  link_item_id uuid references public.store_items (id) on delete set null,
  sort_order integer not null default 0
);
create index if not exists vip_product_benefits_product_idx on public.vip_product_benefits (product_id, sort_order);
create index if not exists vip_product_benefits_link_idx on public.vip_product_benefits (link_item_id) where link_item_id is not null;

create table if not exists public.user_vip (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  product_id uuid not null references public.vip_products (id) on delete cascade,
  purchased_at timestamptz not null default now(),
  expires_at timestamptz not null,
  unique (profile_id, product_id)
);
create index if not exists user_vip_profile_idx on public.user_vip (profile_id);
create index if not exists user_vip_product_idx on public.user_vip (product_id);

-- ---------------------------------------------------------------------------------------------------------------------------------- reads (RLS); writes only through the functions below
alter table public.vip_products enable row level security;
alter table public.vip_product_benefits enable row level security;
alter table public.user_vip enable row level security;
revoke all on public.vip_products, public.vip_product_benefits, public.user_vip from anon;
revoke insert, update, delete, truncate on public.vip_products, public.vip_product_benefits, public.user_vip from authenticated;

-- a hidden (inactive) product is only visible to Master / Super Admin; its benefits follow it
create policy "Active VIP products are readable" on public.vip_products for select to authenticated
  using (status = 'active' or coalesce((select public.is_admin_or_above()), false));
create policy "Benefits of a readable product are readable" on public.vip_product_benefits for select to authenticated
  using (exists (select 1 from public.vip_products p where p.id = product_id));
-- who owns what is cosmetic and public (like user_items); the profiles policy hides a ghost's row, so a ghost's VIP (it never has one) is hidden with it
create policy "VIP ownership is readable" on public.user_vip for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = profile_id));

-- ---------------------------------------------------------------------------------------------------------------------------------- panel: create / change a product with its benefits in one step
-- p_benefits is a JSON array of { kind, title, image_url, link_item_id } in the order to show; it REPLACES the product's benefits. Returns the product id.
create or replace function public.admin_save_vip_product(
  p_id uuid, p_name text, p_tagline text, p_badge_url text, p_price integer, p_days integer,
  p_status text, p_sort integer, p_benefits jsonb default '[]'::jsonb)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_tagline text := nullif(btrim(coalesce(p_tagline, '')), '');
  v_badge text := nullif(btrim(coalesce(p_badge_url, '')), '');
  v_benefits jsonb := coalesce(p_benefits, '[]'::jsonb);
  v_id uuid;
  v_b jsonb;
  v_n integer := 0;
  v_kind text;
  v_title text;
  v_image text;
  v_link uuid;
  v_seen text[] := '{}';
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can manage VIP products';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 40 then raise exception 'A VIP name is 1 to 40 characters'; end if;
  if v_tagline is not null and char_length(v_tagline) > 120 then raise exception 'The short line is 120 characters at most'; end if;
  if p_price is null or p_price < 1 then raise exception 'The price must be at least 1 coin'; end if;
  if p_days is null or p_days < 1 or p_days > 3650 then raise exception 'The days must be between 1 and 3650'; end if;
  if p_status is null or p_status not in ('active', 'inactive') then raise exception 'Status must be active or inactive'; end if;
  if v_badge is not null and (char_length(v_badge) > 600 or v_badge !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/') then
    raise exception 'The badge must be a file uploaded from the panel';
  end if;
  if jsonb_typeof(v_benefits) <> 'array' then raise exception 'The benefits must be a list'; end if;
  if jsonb_array_length(v_benefits) > 40 then raise exception 'A VIP can have at most 40 benefits'; end if;

  -- check every benefit before anything is written
  for v_b in select * from jsonb_array_elements(v_benefits) loop
    v_kind := lower(btrim(coalesce(v_b ->> 'kind', '')));
    v_title := nullif(btrim(coalesce(v_b ->> 'title', '')), '');
    v_image := nullif(btrim(coalesce(v_b ->> 'image_url', '')), '');
    if v_kind !~ '^[a-z][a-z0-9_]{1,39}$' then raise exception 'A benefit has no valid kind'; end if;
    if v_kind = 'custom' and v_title is null then raise exception 'A custom benefit needs a title'; end if;
    if v_title is not null and char_length(v_title) > 40 then raise exception 'A benefit title is 40 characters at most'; end if;
    if v_kind <> 'custom' then
      if v_kind = any(v_seen) then raise exception 'The benefit "%" is in the list twice', v_kind; end if;
      v_seen := v_seen || v_kind;
    end if;
    if v_image is not null and (char_length(v_image) > 600 or v_image !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/') then
      raise exception 'A benefit picture must be a file uploaded from the panel';
    end if;
    v_link := nullif(btrim(coalesce(v_b ->> 'link_item_id', '')), '')::uuid;
    if v_link is not null and not exists (select 1 from public.store_items i where i.id = v_link and i.category <> 'vip') then
      raise exception 'A linked Store item no longer exists (Lucky IDs cannot be linked)';
    end if;
  end loop;

  if p_id is null then
    insert into public.vip_products (name, tagline, badge_url, price_coins, duration_days, status, sort_order, created_by)
      values (v_name, v_tagline, v_badge, p_price, p_days, p_status, coalesce(p_sort, 0), auth.uid())
      returning id into v_id;
  else
    update public.vip_products
       set name = v_name, tagline = v_tagline, badge_url = v_badge, price_coins = p_price, duration_days = p_days,
           status = p_status, sort_order = coalesce(p_sort, 0), updated_at = now()
     where id = p_id
     returning id into v_id;
    if v_id is null then raise exception 'That VIP product no longer exists'; end if;
    delete from public.vip_product_benefits where product_id = v_id;
  end if;

  for v_b in select * from jsonb_array_elements(v_benefits) loop
    insert into public.vip_product_benefits (product_id, kind, title, image_url, link_item_id, sort_order)
      values (v_id, lower(btrim(v_b ->> 'kind')), nullif(btrim(coalesce(v_b ->> 'title', '')), ''), nullif(btrim(coalesce(v_b ->> 'image_url', '')), ''),
              nullif(btrim(coalesce(v_b ->> 'link_item_id', '')), '')::uuid, v_n);
    v_n := v_n + 1;
  end loop;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), case when p_id is null then 'vip_product.create' else 'vip_product.update' end,
            v_id::text || ' ' || v_name || ' (' || p_price || ' coins, ' || p_days || ' days, ' || v_n || ' benefits)', 'info');
  return v_id;
end;
$$;
revoke execute on function public.admin_save_vip_product(uuid, text, text, text, integer, integer, text, integer, jsonb) from public, anon;
grant execute on function public.admin_save_vip_product(uuid, text, text, text, integer, integer, text, integer, jsonb) to authenticated;

-- Deletes a product (its benefits and every person's ownership of it go with it). Items already given stay until their own end date. Returns how many people owned it.
create or replace function public.admin_delete_vip_product(p_id uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_name text;
  v_owners integer;
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can manage VIP products';
  end if;
  select name into v_name from public.vip_products where id = p_id for update;
  if v_name is null then raise exception 'That VIP product no longer exists'; end if;
  select count(*)::int into v_owners from public.user_vip where product_id = p_id and expires_at > now();
  delete from public.vip_products where id = p_id;
  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'vip_product.delete', p_id::text || ' ' || v_name || ' (' || v_owners || ' active owners)', 'warning');
  return v_owners;
end;
$$;
revoke execute on function public.admin_delete_vip_product(uuid) from public, anon;
grant execute on function public.admin_delete_vip_product(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------------- the app: buy
-- Gives the person every Store item linked to the product, until [p_expires]. Not callable by app users (purchase_vip_product calls it).
create or replace function public.vip_grant_items(p_user uuid, p_product uuid, p_expires timestamptz)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  v_row uuid;
begin
  for r in
    select distinct b.link_item_id as item_id, i.category
      from public.vip_product_benefits b
      join public.store_items i on i.id = b.link_item_id
     where b.product_id = p_product and i.category <> 'vip'
  loop
    -- an unexpired copy keeps whichever end date is later; otherwise a fresh copy starts now
    select u.id into v_row from public.user_items u
     where u.profile_id = p_user and u.item_id = r.item_id and u.expires_at > now()
     order by u.expires_at desc limit 1;
    if found then
      update public.user_items set expires_at = greatest(expires_at, p_expires) where id = v_row;
    else
      insert into public.user_items (profile_id, item_id, expires_at, equipped) values (p_user, r.item_id, p_expires, false) returning id into v_row;
    end if;
    -- nothing on in that category yet: put this on (never replaces something the person chose)
    if not exists (
      select 1 from public.user_items u join public.store_items s on s.id = u.item_id
       where u.profile_id = p_user and u.equipped and u.expires_at > now() and s.category = r.category and u.id <> v_row
    ) then
      update public.user_items set equipped = true where id = v_row;
    end if;
  end loop;
end;
$$;
revoke execute on function public.vip_grant_items(uuid, uuid, timestamptz) from public, anon, authenticated;

-- Buys (or adds days to) a VIP product with coins. Returns { product_id, expires_at, price_coins }.
create or replace function public.purchase_vip_product(p_product_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_p public.vip_products%rowtype;
  v_coins bigint;
  v_existing public.user_vip%rowtype;
  v_expires timestamptz;
begin
  if v_me is null then raise exception 'Must be signed in to purchase'; end if;
  if coalesce((select pr.is_ghost from public.profiles pr where pr.id = v_me), false) then
    raise exception 'This account cannot buy';
  end if;
  select * into v_p from public.vip_products where id = p_product_id and status = 'active';
  if not found then raise exception 'This VIP is not available'; end if;

  -- lock the wallet so two taps at once cannot both pass the balance check
  select w.coins into v_coins from public.wallets w where w.profile_id = v_me for update;
  if coalesce(v_coins, 0) < v_p.price_coins then raise exception 'Insufficient coins'; end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (v_me, 'store_purchase', 'coins', -v_p.price_coins, 'vip_products', 'Purchased ' || v_p.name);

  select * into v_existing from public.user_vip where profile_id = v_me and product_id = p_product_id for update;
  if found and v_existing.expires_at > now() then
    v_expires := v_existing.expires_at + make_interval(days => v_p.duration_days);
    update public.user_vip set expires_at = v_expires where id = v_existing.id;
  elsif found then
    v_expires := now() + make_interval(days => v_p.duration_days);
    update public.user_vip set purchased_at = now(), expires_at = v_expires where id = v_existing.id;
  else
    v_expires := now() + make_interval(days => v_p.duration_days);
    insert into public.user_vip (profile_id, product_id, expires_at) values (v_me, p_product_id, v_expires);
  end if;

  perform public.vip_grant_items(v_me, p_product_id, v_expires);
  return jsonb_build_object('product_id', p_product_id, 'expires_at', v_expires, 'price_coins', v_p.price_coins);
end;
$$;
revoke execute on function public.purchase_vip_product(uuid) from public, anon;
grant execute on function public.purchase_vip_product(uuid) to authenticated;
