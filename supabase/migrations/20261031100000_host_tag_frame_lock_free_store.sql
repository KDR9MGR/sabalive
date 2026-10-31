-- Three panel requests of 2026-10-31 (the room-skin one needs no database change: Bag -> Assign item -> Room skin already works through admin_assign_store_item).
--
-- 1. AUTOMATIC HOST TAG. One tag can be marked "give to every host automatically" (profile_tags.auto_for_hosts, at most one tag at a time). A person gets it the moment an agency
--    accepts them: a host application becomes 'approved', or a host row gets an agency for the first time (host code, agency approval). A transfer between agencies does not give it
--    again (so a tag taken off by hand stays off), and an independent host (the app creates a host row for anyone who goes live, with no agency) is not tagged. The triggers fail open: a
--    tag problem never blocks approving a host. admin_set_host_auto_tag marks / unmarks the tag, admin_give_host_tag_to_current_hosts adds it to the hosts that already exist.
--    Both need staff_can_manage_tags() (Super Admin, Master by default). admin_save_profile_tag is not touched.
-- 2. FRAME LOCK. frames.locked and store_items.locked (the panel offers it for frames): only a Super Admin or Master can lock / unlock (trigger), and while it is locked no OTHER staff
--    account can assign it: the user_frames insert policies of the two granted switches and admin_assign_store_item check the lock. A Super Admin / Master can still assign it.
--    Users are not affected (their own unlocks by level or coins go through claim_frame as before).
-- 3. FREE STORE ITEMS. store_items.price_coins may be 0 (it had to be above 0, unlike Lucky IDs). purchase_store_item then charges nothing and writes no ledger row; a free item someone
--    already owns (unexpired) is refused instead of extended, so tapping can't stack unlimited days. Paid purchases behave exactly as before. An old app shows "0 coins" for a free item
--    and the purchase works; the new app shows "Free".
--
-- Additive for the apps in the field. Rollback: supabase/rollbacks/20261031100000_down.sql. Test: scripts/db/tests/panel_batch_20261031_test.sql.
set local lock_timeout = '5s';

-- ------------------------------------------------------------------------------------------------------------ 1. automatic Host tag
alter table public.profile_tags add column if not exists auto_for_hosts boolean not null default false;
create unique index if not exists profile_tags_one_auto_for_hosts on public.profile_tags ((true)) where auto_for_hosts;

create or replace function public._give_host_tag(p_profile uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profile_tag_assignments (profile_id, tag_id, assigned_by)
  select p_profile, t.id, null
    from public.profile_tags t
   where t.auto_for_hosts and t.status = 'active'
     and exists (select 1 from public.profiles p where p.id = p_profile and not coalesce(p.is_ghost, false))
  on conflict do nothing;
exception when others then
  null; -- never block a host being accepted because of a tag
end;
$$;
revoke execute on function public._give_host_tag(uuid) from public, anon, authenticated;

create or replace function public.host_accepted_gets_tag()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_table_name = 'host_applications' then
    perform public._give_host_tag(new.applicant_id);
  else
    perform public._give_host_tag(new.profile_id);
  end if;
  return null;
end;
$$;
revoke execute on function public.host_accepted_gets_tag() from public, anon, authenticated;

drop trigger if exists host_profiles_give_tag_insert on public.host_profiles;
create trigger host_profiles_give_tag_insert after insert on public.host_profiles
  for each row when (new.agency_id is not null) execute function public.host_accepted_gets_tag();
drop trigger if exists host_profiles_give_tag_update on public.host_profiles;
create trigger host_profiles_give_tag_update after update of agency_id on public.host_profiles
  for each row when (new.agency_id is not null and old.agency_id is null) execute function public.host_accepted_gets_tag();
drop trigger if exists host_applications_give_tag on public.host_applications;
create trigger host_applications_give_tag after update of status on public.host_applications
  for each row when (new.status = 'approved' and old.status is distinct from 'approved') execute function public.host_accepted_gets_tag();

create or replace function public.admin_set_host_auto_tag(p_tag uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_name text;
begin
  if not public.staff_can_manage_tags() then
    raise exception 'Not allowed to manage tags';
  end if;
  select name into v_name from public.profile_tags where id = p_tag for update;
  if v_name is null then raise exception 'That tag does not exist'; end if;
  if coalesce(p_on, false) then
    update public.profile_tags set auto_for_hosts = false where auto_for_hosts and id <> p_tag;
    update public.profile_tags set auto_for_hosts = true where id = p_tag;
  else
    update public.profile_tags set auto_for_hosts = false where id = p_tag;
  end if;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), case when coalesce(p_on, false) then 'tag.auto_host_on' else 'tag.auto_host_off' end, v_name, 'info');
end;
$$;
revoke execute on function public.admin_set_host_auto_tag(uuid, boolean) from public, anon;
grant execute on function public.admin_set_host_auto_tag(uuid, boolean) to authenticated;

-- adds the automatic Host tag to the hosts that already exist (accepted into an agency, or approved on an application); returns how many people it was added to
create or replace function public.admin_give_host_tag_to_current_hosts()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_tag uuid;
  v_name text;
  v_n integer;
begin
  if not public.staff_can_manage_tags() then
    raise exception 'Not allowed to manage tags';
  end if;
  select id, name into v_tag, v_name from public.profile_tags where auto_for_hosts;
  if v_tag is null then raise exception 'No tag is set to be given to hosts automatically yet'; end if;
  with ins as (
    insert into public.profile_tag_assignments (profile_id, tag_id, assigned_by)
    select hp.profile_id, v_tag, auth.uid()
      from public.host_profiles hp
      join public.profiles p on p.id = hp.profile_id and not coalesce(p.is_ghost, false)
     where hp.agency_id is not null
        or exists (select 1 from public.host_applications a where a.applicant_id = hp.profile_id and a.status = 'approved')
    on conflict do nothing
    returning 1
  )
  select count(*)::int into v_n from ins;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'tag.host_tag_to_current_hosts', v_name || ' -> ' || v_n || ' hosts', 'info');
  return v_n;
end;
$$;
revoke execute on function public.admin_give_host_tag_to_current_hosts() from public, anon;
grant execute on function public.admin_give_host_tag_to_current_hosts() to authenticated;

-- ------------------------------------------------------------------------------------------------------------ 2. frame lock
alter table public.frames add column if not exists locked boolean not null default false;
alter table public.store_items add column if not exists locked boolean not null default false;

create or replace function public.guard_locked_flag()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if (tg_op = 'INSERT' and new.locked) or (tg_op = 'UPDATE' and new.locked is distinct from old.locked) then
    if auth.uid() is not null and not coalesce(public.is_admin_or_above(), false) then
      raise exception 'Only a Super Admin or Master can lock or unlock a frame';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.guard_locked_flag() from public, anon, authenticated;
drop trigger if exists frames_guard_locked on public.frames;
create trigger frames_guard_locked before insert or update on public.frames
  for each row execute function public.guard_locked_flag();
drop trigger if exists store_items_guard_locked on public.store_items;
create trigger store_items_guard_locked before insert or update on public.store_items
  for each row execute function public.guard_locked_flag();

create or replace function public.frame_is_locked(p_frame uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select f.locked from public.frames f where f.id = p_frame), false);
$$;
revoke execute on function public.frame_is_locked(uuid) from public, anon;
grant execute on function public.frame_is_locked(uuid) to authenticated;

-- the two granted switches may assign a frame only while it is not locked (the "Admins grant frames" policy, Super Admin / Master, is unchanged)
drop policy if exists "Granted manage_profile_frames: insert user_frames" on public.user_frames;
create policy "Granted manage_profile_frames: insert user_frames" on public.user_frames for insert
  with check ((select public.staff_can('manage_profile_frames')) and (public.is_admin_or_above() or not public.frame_is_locked(frame_id)));
drop policy if exists "Granted view_user_profile: insert user_frames" on public.user_frames;
create policy "Granted view_user_profile: insert user_frames" on public.user_frames for insert
  with check ((select public.staff_can('view_user_profile')) and (public.is_admin_or_above() or not public.frame_is_locked(frame_id)));

-- same body as 20261012100000 plus the lock check
create or replace function public.admin_assign_store_item(p_user uuid, p_item uuid, p_days integer default null::integer, p_equip boolean default false)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
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
  if v_item.locked and not coalesce(public.is_admin_or_above(), false) then
    raise exception 'This item is locked: only a Super Admin or Master can assign it';
  end if;
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

-- ------------------------------------------------------------------------------------------------------------ 3. free store items
alter table public.store_items drop constraint if exists store_items_price_coins_check;
alter table public.store_items add constraint store_items_price_coins_check check (price_coins >= 0);

-- same body as 20260924100500 plus: a price of 0 charges nothing (no ledger row), and a free item already owned is refused
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

  if v_item.price_coins > 0 then
    if (select coins from public.wallets where profile_id = v_me) < v_item.price_coins then
      raise exception 'Insufficient coins';
    end if;
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
      values (v_me, 'store_purchase', 'coins', -v_item.price_coins, 'store_items',
              'Purchased ' || v_item.name);
  end if;

  select * into v_existing from public.user_items
    where profile_id = v_me and item_id = p_item_id and expires_at > now();

  if found then
    if v_item.price_coins = 0 then
      raise exception 'You already have this item';
    end if;
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
