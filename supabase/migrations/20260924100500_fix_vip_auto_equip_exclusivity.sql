-- purchase_store_item's "fresh purchase" branch auto-equips VIP items but
-- never unequipped a sibling VIP the caller already had active — buying
-- VIP Silver while VIP Bronze was still equipped left both marked
-- equipped=true. Same mutual-exclusion set_item_equipped already does for
-- an explicit equip, just applied here too before the fresh insert.
create or replace function public.purchase_store_item(p_item_id uuid)
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

  select * into v_existing from public.user_items
    where profile_id = v_me and item_id = p_item_id and expires_at > now();

  if found then
    update public.user_items
      set expires_at = expires_at + make_interval(days => v_item.duration_days)
      where id = v_existing.id
      returning * into v_row;
  else
    if v_item.category = 'vip' then
      update public.user_items set equipped = false
        where profile_id = v_me and equipped = true
          and item_id in (select id from public.store_items where category = 'vip');
    end if;
    insert into public.user_items (profile_id, item_id, expires_at, equipped)
      values (v_me, p_item_id, now() + make_interval(days => v_item.duration_days),
              v_item.category = 'vip')
      returning * into v_row;
  end if;

  return v_row;
end;
$$;
