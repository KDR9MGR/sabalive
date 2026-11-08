-- VIP opens for everyone, and a purchase puts on everything the VIP gives (owner, 2026-11-09: "when a vip product is purchased all assets in it get applied to that user right away
-- and the user can equip and unequip it from the Bag ... should work even if the panel switch is off").
--   * purchase_vip_product no longer looks at the vip_enabled switch (it only had that check since 20261108105000); the panel toggle is gone, the key left in app_config is harmless.
--   * vip_grant_items now puts each given Store item ON (it used to do so only when nothing was on in that category); the item that was on comes off but stays in the Bag.
-- Only the BODIES of two VIP-only functions change (same names, arguments and return types); nothing an old app calls.
set local lock_timeout = '5s';

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
    -- put it on right away (owner, 2026-11-09: "all assets in it get applied right away"): whatever the person wore in that category comes off (they keep it and can
    -- put it back from the Bag), and they can take this one off, or put it on again, from the Bag too.
    update public.user_items u set equipped = false
     where u.profile_id = p_user and u.equipped and u.id <> v_row
       and u.item_id in (select s.id from public.store_items s where s.category = r.category);
    update public.user_items set equipped = true where id = v_row;
  end loop;
end;
$$;
revoke execute on function public.vip_grant_items(uuid, uuid, timestamptz) from public, anon, authenticated;

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
