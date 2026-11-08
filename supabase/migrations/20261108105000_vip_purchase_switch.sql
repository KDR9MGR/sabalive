-- VIP purchases follow the owner's switch (app_config.feature_flags.vip_enabled; panel: Release Settings -> "VIP products"). The VIP tables and functions were already on production
-- (20261106120000) with no switch, so this replaces ONLY the body of purchase_vip_product (same name, arguments and return type) to refuse "VIP is coming soon" while the switch is off.
-- The next migration turns the switch on.
set local lock_timeout = '5s';

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
  -- the owner's switch (panel: Release Settings -> VIP products): off by default, so VIP can be "coming soon" in the app and closed here too
  if not coalesce((select feature_flags -> 'vip_enabled' = 'true'::jsonb from public.app_config where id), false) then
    raise exception 'VIP is coming soon';
  end if;
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
