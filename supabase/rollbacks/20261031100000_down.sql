-- Down script for supabase/migrations/20261031100000_host_tag_frame_lock_free_store.sql
-- Applied BY HAND only. Removes the automatic Host tag (triggers, functions, column), the frame lock (column, trigger, policies back to what they were, assign function back
-- to its previous body) and puts purchase_store_item back. Tags already given to hosts stay (they are ordinary tag assignments). The price rule goes back to "above 0" for NEW
-- and edited rows only (NOT VALID), so a free item that was created stays readable until someone edits it; set its price first if you want it cleaned.
begin;
set local lock_timeout = '5s';

-- 1. automatic Host tag
drop trigger if exists host_profiles_give_tag_insert on public.host_profiles;
drop trigger if exists host_profiles_give_tag_update on public.host_profiles;
drop trigger if exists host_applications_give_tag on public.host_applications;
drop function if exists public.host_accepted_gets_tag();
drop function if exists public._give_host_tag(uuid);
drop function if exists public.admin_set_host_auto_tag(uuid, boolean);
drop function if exists public.admin_give_host_tag_to_current_hosts();
drop index if exists public.profile_tags_one_auto_for_hosts;
alter table public.profile_tags drop column if exists auto_for_hosts;

-- 2. frame lock: policies as they were (20261006140000 and 20261012100000)
drop policy if exists "Granted manage_profile_frames: insert user_frames" on public.user_frames;
create policy "Granted manage_profile_frames: insert user_frames" on public.user_frames for insert with check ((select public.staff_can('manage_profile_frames')));
drop policy if exists "Granted view_user_profile: insert user_frames" on public.user_frames;
create policy "Granted view_user_profile: insert user_frames" on public.user_frames for insert
  with check ((select public.staff_can('view_user_profile')));
drop trigger if exists frames_guard_locked on public.frames;
drop trigger if exists store_items_guard_locked on public.store_items;
drop function if exists public.guard_locked_flag();
drop function if exists public.frame_is_locked(uuid);
alter table public.frames drop column if exists locked;
alter table public.store_items drop column if exists locked;

CREATE OR REPLACE FUNCTION public.admin_assign_store_item(p_user uuid, p_item uuid, p_days integer DEFAULT NULL::integer, p_equip boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item public.store_items%rowtype;
  v_days integer;
  v_existing public.user_items%rowtype;
  v_id uuid;
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Only a Master or Super Admin can assign items';
  end if;

  select * into v_item from public.store_items where id = p_item;
  if not found then raise exception 'That item does not exist'; end if;
  if v_item.category = 'vip' then
    raise exception 'Lucky IDs are assigned from the Lucky ID page';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'That user does not exist';
  end if;

  v_days := coalesce(p_days, v_item.duration_days);
  if v_days < 1 or v_days > 3650 then raise exception 'Days must be between 1 and 3650'; end if;

  -- an unexpired copy is extended; otherwise a fresh one starts now
  select * into v_existing from public.user_items
   where profile_id = p_user and item_id = p_item and expires_at > now()
   order by expires_at desc limit 1;
  if found then
    update public.user_items set expires_at = expires_at + make_interval(days => v_days)
     where id = v_existing.id returning id into v_id;
  else
    insert into public.user_items (profile_id, item_id, expires_at, equipped)
    values (p_user, p_item, now() + make_interval(days => v_days), false)
    returning id into v_id;
  end if;

  if p_equip then
    update public.user_items set equipped = false
     where profile_id = p_user and equipped
       and item_id in (select id from public.store_items where category = v_item.category);
    update public.user_items set equipped = true where id = v_id;
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.item_assigned', p_user::text || ' <- ' || v_item.name || ' (' || v_days || 'd)', 'info');
end;
$function$;

-- 3. free store items
alter table public.store_items drop constraint if exists store_items_price_coins_check;
alter table public.store_items add constraint store_items_price_coins_check check (price_coins > 0) not valid;

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
commit;
