-- Lucky IDs may start with zeros (e.g. 0786). The number is still stored as a
-- number (profiles.display_id and every lookup stay numeric); `digits` records
-- the written width so 786 is shown as 0786, and an owner's profiles.display_id_width
-- carries it to the app. Everything here is idempotent.
alter table public.lucky_ids add column if not exists digits smallint;
alter table public.profiles add column if not exists display_id_width smallint;

alter table public.lucky_ids drop constraint if exists lucky_ids_number_check;
alter table public.lucky_ids add constraint lucky_ids_number_check
  check (number between 1 and 999999999999);
alter table public.lucky_ids drop constraint if exists lucky_ids_digits_check;
alter table public.lucky_ids add constraint lucky_ids_digits_check
  check (digits is null or (digits >= 4 and digits <= 12 and digits > length(number::text)));

-- release: give back the owner's own ID (never padded)
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
    update public.profiles set display_id = r.original_display_id, display_id_width = null where id = r.owner_id;
  end if;
  update public.lucky_ids
     set owner_id = null, expires_at = null, original_display_id = null, assigned_by = null
   where id = p_lucky;
end;
$$;
revoke execute on function public.lucky_release(uuid) from public, anon, authenticated;

-- claim: swap to the lucky number, with its written width
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

  select * into v_prev from public.lucky_ids where owner_id = p_user for update;
  if found then
    v_original := v_prev.original_display_id;
    update public.lucky_ids
       set owner_id = null, expires_at = null, original_display_id = null, assigned_by = null
     where id = v_prev.id;
  end if;

  update public.profiles set display_id = r.number, display_id_width = r.digits where id = p_user;
  update public.lucky_ids set
    owner_id = p_user,
    expires_at = now() + make_interval(days => p_days),
    original_display_id = v_original,
    assigned_by = p_by
  where id = p_lucky;
end;
$$;
revoke execute on function public.lucky_claim(uuid, uuid, integer, uuid) from public, anon, authenticated;

-- Panel: add / edit a number. The number now arrives as text so '0786' keeps its zero.
drop function if exists public.admin_save_lucky_id(uuid, bigint, integer, integer, text);
create or replace function public.admin_save_lucky_id(
  p_id uuid, p_number text, p_price integer, p_days integer, p_status text
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_cur public.lucky_ids%rowtype;
  v_text text := btrim(coalesce(p_number, ''));
  v_num bigint;
  v_digits smallint;
begin
  if not coalesce(public.is_admin_or_above(), false) then
    raise exception 'Only a Master or Super Admin can manage Lucky IDs';
  end if;
  perform public.require_capability('manage_coins');
  if p_status not in ('active', 'inactive') then raise exception 'Status must be active or inactive'; end if;
  if v_text !~ '^[0-9]+$' then raise exception 'A Lucky ID can only contain digits'; end if;
  if length(v_text) < 4 then raise exception 'A Lucky ID needs at least 4 digits'; end if;
  if length(v_text) > 12 then raise exception 'A Lucky ID can have at most 12 digits'; end if;
  v_num := v_text::bigint;
  if v_num < 1 then raise exception 'A Lucky ID cannot be all zeros'; end if;
  -- only record a width when there are leading zeros to keep
  v_digits := case when v_text like '0%' then length(v_text) end;

  if p_id is null then
    if exists (select 1 from public.lucky_ids where number = v_num) then
      raise exception 'Lucky ID % already exists', v_text;
    end if;
    if exists (select 1 from public.profiles where display_id = v_num) then
      raise exception 'Someone already has ID % as their app ID', v_text;
    end if;
    insert into public.lucky_ids (number, digits, price_coins, duration_days, status)
    values (v_num, v_digits, p_price, p_days, p_status) returning id into v_id;
  else
    select * into v_cur from public.lucky_ids where id = p_id for update;
    if not found then raise exception 'That Lucky ID does not exist'; end if;
    if v_cur.number <> v_num or v_cur.digits is distinct from v_digits then
      if v_cur.owner_id is not null then raise exception 'Revoke the Lucky ID before changing its number'; end if;
      if v_cur.number <> v_num then
        if exists (select 1 from public.lucky_ids where number = v_num) then
          raise exception 'Lucky ID % already exists', v_text;
        end if;
        if exists (select 1 from public.profiles where display_id = v_num) then
          raise exception 'Someone already has ID % as their app ID', v_text;
        end if;
      end if;
    end if;
    update public.lucky_ids
       set number = v_num, digits = v_digits, price_coins = p_price, duration_days = p_days, status = p_status
     where id = p_id;
    v_id := p_id;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.admin_save_lucky_id(uuid, text, integer, integer, text) from public, anon;
grant execute on function public.admin_save_lucky_id(uuid, text, integer, integer, text) to authenticated;

-- ledger note shows the padded number
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
    values (v_me, 'store_purchase', 'coins', -r.price_coins, 'lucky_ids', p_lucky,
            'Lucky ID ' || lpad(r.number::text, coalesce(r.digits, 0), '0'));
  end if;
end;
$$;
revoke execute on function public.purchase_lucky_id(uuid) from public, anon;
grant execute on function public.purchase_lucky_id(uuid) to authenticated;
