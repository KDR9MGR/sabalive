-- Lucky IDs: special app-facing ID numbers (e.g. 888888). The panel keeps the
-- catalog; a user can buy one in the Store, or a Master / Super Admin can assign
-- one. While owned it REPLACES the user's app ID (profiles.display_id) everywhere
-- that ID is shown or searched; when it expires or is revoked their own ID is put
-- back. Replaces the old VIP-tier "Lucky ID" tab (those store_items are left alone
-- but no longer shown).
create table public.lucky_ids (
  id uuid primary key default gen_random_uuid(),
  number bigint not null unique check (number between 1000 and 999999999999),
  price_coins integer not null default 0 check (price_coins >= 0),
  duration_days integer not null default 30 check (duration_days > 0),
  status text not null default 'active' check (status in ('active', 'inactive')),
  owner_id uuid references public.profiles (id) on delete set null,
  expires_at timestamptz,
  -- the owner's own app ID, put back when this one ends
  original_display_id bigint,
  assigned_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
-- one lucky ID per person at a time
create unique index lucky_ids_one_per_owner on public.lucky_ids (owner_id) where owner_id is not null;

alter table public.lucky_ids enable row level security;
create policy "Lucky IDs: active ones, your own, and everything for staff"
  on public.lucky_ids for select
  using (status = 'active' or owner_id = auth.uid() or public.is_admin_or_above());
-- writes only through the RPCs below

-- New profiles never receive a number reserved as a lucky ID.
create or replace function public.next_profile_display_id()
returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  v bigint;
begin
  loop
    v := nextval('public.profiles_display_id_seq');
    exit when not exists (select 1 from public.lucky_ids where number = v);
  end loop;
  return v;
end;
$$;
revoke execute on function public.next_profile_display_id() from public, anon, authenticated;
alter table public.profiles alter column display_id set default public.next_profile_display_id();

-- put a lucky ID back in the pool and restore the owner's own ID
create or replace function public.lucky_release(p_lucky uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r public.lucky_ids%rowtype;
begin
  select * into r from public.lucky_ids where id = p_lucky for update;
  if not found or r.owner_id is null then return; end if;
  if r.original_display_id is not null then
    update public.profiles set display_id = r.original_display_id where id = r.owner_id;
  end if;
  update public.lucky_ids
     set owner_id = null, expires_at = null, original_display_id = null, assigned_by = null
   where id = p_lucky;
end;
$$;
revoke execute on function public.lucky_release(uuid) from public, anon, authenticated;

-- give a lucky ID to a user for N days (they swap to it; any earlier one is released)
create or replace function public.lucky_claim(p_lucky uuid, p_user uuid, p_days integer, p_by uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r public.lucky_ids%rowtype;
  v_prev public.lucky_ids%rowtype;
  v_original bigint;
begin
  select * into r from public.lucky_ids where id = p_lucky for update;
  if not found then raise exception 'That Lucky ID does not exist'; end if;
  if r.status <> 'active' then raise exception 'That Lucky ID is not for sale'; end if;
  if r.owner_id is not null and r.expires_at <= now() then
    perform public.lucky_release(p_lucky);
    select * into r from public.lucky_ids where id = p_lucky for update;
  end if;
  if r.owner_id is not null then raise exception 'That Lucky ID is already taken'; end if;

  select display_id into v_original from public.profiles where id = p_user;
  if v_original is null then raise exception 'That user does not exist'; end if;

  -- already wearing another lucky ID: free it, and keep the user's real one for later
  select * into v_prev from public.lucky_ids where owner_id = p_user for update;
  if found then
    v_original := v_prev.original_display_id;
    update public.lucky_ids
       set owner_id = null, expires_at = null, original_display_id = null, assigned_by = null
     where id = v_prev.id;
  end if;

  update public.profiles set display_id = r.number where id = p_user;
  update public.lucky_ids set
    owner_id = p_user,
    expires_at = now() + make_interval(days => p_days),
    original_display_id = v_original,
    assigned_by = p_by
  where id = p_lucky;
end;
$$;
revoke execute on function public.lucky_claim(uuid, uuid, integer, uuid) from public, anon, authenticated;

-- a user buys one with coins
create or replace function public.purchase_lucky_id(p_lucky uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  r public.lucky_ids%rowtype;
begin
  if v_me is null then raise exception 'Must be signed in to purchase'; end if;
  select * into r from public.lucky_ids where id = p_lucky;
  if not found or r.status <> 'active' then raise exception 'That Lucky ID is not available'; end if;
  if r.owner_id is not null and r.expires_at > now() then raise exception 'That Lucky ID is already taken'; end if;
  if r.price_coins > 0 and (select coins from public.wallets where profile_id = v_me) < r.price_coins then
    raise exception 'Insufficient coins';
  end if;
  perform public.lucky_claim(p_lucky, v_me, r.duration_days, null);
  if r.price_coins > 0 then
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (v_me, 'store_purchase', 'coins', -r.price_coins, 'lucky_ids', p_lucky, 'Lucky ID ' || r.number);
  end if;
end;
$$;
revoke execute on function public.purchase_lucky_id(uuid) from public, anon;
grant execute on function public.purchase_lucky_id(uuid) to authenticated;

-- Panel: add / edit a number
create or replace function public.admin_save_lucky_id(
  p_id uuid, p_number bigint, p_price integer, p_days integer, p_status text
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_cur public.lucky_ids%rowtype;
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can manage Lucky IDs';
  end if;
  perform public.require_capability('manage_coins');
  if p_status not in ('active', 'inactive') then raise exception 'Status must be active or inactive'; end if;
  if p_number is null or p_number < 1000 then raise exception 'A Lucky ID needs at least 4 digits'; end if;

  if p_id is null then
    if exists (select 1 from public.profiles where display_id = p_number) then
      raise exception 'Someone already has ID % as their app ID', p_number;
    end if;
    insert into public.lucky_ids (number, price_coins, duration_days, status)
    values (p_number, p_price, p_days, p_status) returning id into v_id;
  else
    select * into v_cur from public.lucky_ids where id = p_id for update;
    if not found then raise exception 'That Lucky ID does not exist'; end if;
    if v_cur.number <> p_number then
      if v_cur.owner_id is not null then raise exception 'Revoke the Lucky ID before changing its number'; end if;
      if exists (select 1 from public.profiles where display_id = p_number) then
        raise exception 'Someone already has ID % as their app ID', p_number;
      end if;
    end if;
    update public.lucky_ids
       set number = p_number, price_coins = p_price, duration_days = p_days, status = p_status
     where id = p_id;
    v_id := p_id;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.admin_save_lucky_id(uuid, bigint, integer, integer, text) from public, anon;
grant execute on function public.admin_save_lucky_id(uuid, bigint, integer, integer, text) to authenticated;

create or replace function public.admin_delete_lucky_id(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can manage Lucky IDs';
  end if;
  perform public.require_capability('manage_coins');
  if exists (select 1 from public.lucky_ids where id = p_id and owner_id is not null) then
    raise exception 'Revoke the Lucky ID from its owner first';
  end if;
  delete from public.lucky_ids where id = p_id;
end;
$$;
revoke execute on function public.admin_delete_lucky_id(uuid) from public, anon;
grant execute on function public.admin_delete_lucky_id(uuid) to authenticated;

-- Panel: give one to a user (free) / take it back
create or replace function public.admin_assign_lucky_id(p_lucky uuid, p_user uuid, p_days integer default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_days integer;
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can assign Lucky IDs';
  end if;
  perform public.require_capability('manage_users');
  select coalesce(p_days, duration_days) into v_days from public.lucky_ids where id = p_lucky;
  if v_days is null then raise exception 'That Lucky ID does not exist'; end if;
  if v_days < 1 or v_days > 3650 then raise exception 'Days must be between 1 and 3650'; end if;
  perform public.lucky_claim(p_lucky, p_user, v_days, auth.uid());
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.lucky_id_assigned', p_user::text || ' <- ' || p_lucky::text, 'info');
end;
$$;
revoke execute on function public.admin_assign_lucky_id(uuid, uuid, integer) from public, anon;
grant execute on function public.admin_assign_lucky_id(uuid, uuid, integer) to authenticated;

create or replace function public.admin_revoke_lucky_id(p_lucky uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can revoke Lucky IDs';
  end if;
  perform public.require_capability('manage_users');
  perform public.lucky_release(p_lucky);
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.lucky_id_revoked', p_lucky::text, 'warning');
end;
$$;
revoke execute on function public.admin_revoke_lucky_id(uuid) from public, anon;
grant execute on function public.admin_revoke_lucky_id(uuid) to authenticated;

-- expired ones go back to their owners' own IDs
create or replace function public.expire_lucky_ids()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r record;
begin
  for r in select id from public.lucky_ids where owner_id is not null and expires_at <= now() loop
    perform public.lucky_release(r.id);
  end loop;
end;
$$;
revoke execute on function public.expire_lucky_ids() from public, anon, authenticated;

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'expire-lucky-ids') then
    perform cron.schedule('expire-lucky-ids', '*/10 * * * *', $sql$select public.expire_lucky_ids()$sql$);
  end if;
end;
$outer$;
