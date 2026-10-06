-- Per-account capability grants, part 2: every feature switch in Access Control can now be given to
-- a Global / Country / Sub Admin or Agency account, not just a Master.
--
-- staff_can(key) is true for Master / Super Admin, or for a lower-role account whose permissions JSON has the
-- key explicitly true (and the key is one of the feature switches below). The data each feature needs is opened
-- with NEW permissive policies, one per table/command, that only the grant satisfies: no existing policy is changed,
-- so nothing a normal app user, host or Master can do today changes. Not grantable to non-Masters (platform level):
-- manage_admins, edit_config, manage_infra, manage_system, view_audit, impersonate, monitor_lives.
-- Rollback: supabase/rollbacks/20261006140000_down.sql.
create or replace function public.staff_can(p_key text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.is_admin_or_above(), false)
    or exists (
      select 1 from public.staff_roles s
       where s.user_id = auth.uid()
         and nullif(s.permissions ->> p_key, '')::boolean is true
         and (
           p_key in ('manage_agencies', 'manage_coins', 'manage_live_requests', 'manage_lucky_box', 'manage_badges',
                     'manage_leaderboard_frame', 'manage_profile_frames', 'manage_content', 'view_reports',
                     'manage_levels', 'manage_support')
           or (p_key = 'manage_users' and s.role in ('global_admin', 'country_admin', 'sub_admin'))
           or (p_key = 'run_payroll')
         )
    );
$$;
revoke execute on function public.staff_can(text) from public, anon;
grant execute on function public.staff_can(text) to authenticated;

-- manage_levels / manage_support are enforced through staff_cap_on(): a lower role now passes it with the grant.
create or replace function public.staff_cap_on(p_key text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select case public.current_staff_role()
    when 'super_admin' then true
    when 'admin' then coalesce(
      nullif((select s.permissions ->> p_key from public.staff_roles s where s.user_id = auth.uid()), '')::boolean,
      true)
    else coalesce(public.staff_can(p_key), false)
  end;
$$;

-- ---- manage_content
drop policy if exists "Granted manage_content: select announcements" on public.announcements;
create policy "Granted manage_content: select announcements" on public.announcements for select using ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: insert announcements" on public.announcements;
create policy "Granted manage_content: insert announcements" on public.announcements for insert with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: update announcements" on public.announcements;
create policy "Granted manage_content: update announcements" on public.announcements for update using ((select public.staff_can('manage_content'))) with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: select banners" on public.banners;
create policy "Granted manage_content: select banners" on public.banners for select using ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: insert banners" on public.banners;
create policy "Granted manage_content: insert banners" on public.banners for insert with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: update banners" on public.banners;
create policy "Granted manage_content: update banners" on public.banners for update using ((select public.staff_can('manage_content'))) with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: update banner_settings" on public.banner_settings;
create policy "Granted manage_content: update banner_settings" on public.banner_settings for update using ((select public.staff_can('manage_content'))) with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: select legal_pages" on public.legal_pages;
create policy "Granted manage_content: select legal_pages" on public.legal_pages for select using ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: insert legal_pages" on public.legal_pages;
create policy "Granted manage_content: insert legal_pages" on public.legal_pages for insert with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: update legal_pages" on public.legal_pages;
create policy "Granted manage_content: update legal_pages" on public.legal_pages for update using ((select public.staff_can('manage_content'))) with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: select live_emojis" on public.live_emojis;
create policy "Granted manage_content: select live_emojis" on public.live_emojis for select using ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: insert live_emojis" on public.live_emojis;
create policy "Granted manage_content: insert live_emojis" on public.live_emojis for insert with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: update live_emojis" on public.live_emojis;
create policy "Granted manage_content: update live_emojis" on public.live_emojis for update using ((select public.staff_can('manage_content'))) with check ((select public.staff_can('manage_content')));
drop policy if exists "Granted manage_content: delete live_emojis" on public.live_emojis;
create policy "Granted manage_content: delete live_emojis" on public.live_emojis for delete using ((select public.staff_can('manage_content')));
-- ---- manage_badges
drop policy if exists "Granted manage_badges: select badges" on public.badges;
create policy "Granted manage_badges: select badges" on public.badges for select using ((select public.staff_can('manage_badges')));
drop policy if exists "Granted manage_badges: insert badges" on public.badges;
create policy "Granted manage_badges: insert badges" on public.badges for insert with check ((select public.staff_can('manage_badges')));
drop policy if exists "Granted manage_badges: update badges" on public.badges;
create policy "Granted manage_badges: update badges" on public.badges for update using ((select public.staff_can('manage_badges'))) with check ((select public.staff_can('manage_badges')));
drop policy if exists "Granted manage_badges: insert user_badges" on public.user_badges;
create policy "Granted manage_badges: insert user_badges" on public.user_badges for insert with check ((select public.staff_can('manage_badges')));
-- ---- manage_profile_frames
drop policy if exists "Granted manage_profile_frames: select frames" on public.frames;
create policy "Granted manage_profile_frames: select frames" on public.frames for select using ((select public.staff_can('manage_profile_frames')));
drop policy if exists "Granted manage_profile_frames: insert frames" on public.frames;
create policy "Granted manage_profile_frames: insert frames" on public.frames for insert with check ((select public.staff_can('manage_profile_frames')));
drop policy if exists "Granted manage_profile_frames: update frames" on public.frames;
create policy "Granted manage_profile_frames: update frames" on public.frames for update using ((select public.staff_can('manage_profile_frames'))) with check ((select public.staff_can('manage_profile_frames')));
drop policy if exists "Granted manage_profile_frames: insert user_frames" on public.user_frames;
create policy "Granted manage_profile_frames: insert user_frames" on public.user_frames for insert with check ((select public.staff_can('manage_profile_frames')));
-- ---- manage_leaderboard_frame
drop policy if exists "Granted manage_leaderboard_frame: select leaderboard_frames" on public.leaderboard_frames;
create policy "Granted manage_leaderboard_frame: select leaderboard_frames" on public.leaderboard_frames for select using ((select public.staff_can('manage_leaderboard_frame')));
drop policy if exists "Granted manage_leaderboard_frame: insert leaderboard_frames" on public.leaderboard_frames;
create policy "Granted manage_leaderboard_frame: insert leaderboard_frames" on public.leaderboard_frames for insert with check ((select public.staff_can('manage_leaderboard_frame')));
drop policy if exists "Granted manage_leaderboard_frame: update leaderboard_frames" on public.leaderboard_frames;
create policy "Granted manage_leaderboard_frame: update leaderboard_frames" on public.leaderboard_frames for update using ((select public.staff_can('manage_leaderboard_frame'))) with check ((select public.staff_can('manage_leaderboard_frame')));
-- ---- manage_lucky_box
drop policy if exists "Granted manage_lucky_box: update lucky_box_config" on public.lucky_box_config;
create policy "Granted manage_lucky_box: update lucky_box_config" on public.lucky_box_config for update using ((select public.staff_can('manage_lucky_box'))) with check ((select public.staff_can('manage_lucky_box')));
-- ---- manage_live_requests
drop policy if exists "Granted manage_live_requests: select live_requests" on public.live_requests;
create policy "Granted manage_live_requests: select live_requests" on public.live_requests for select using ((select public.staff_can('manage_live_requests')));
drop policy if exists "Granted manage_live_requests: update live_requests" on public.live_requests;
create policy "Granted manage_live_requests: update live_requests" on public.live_requests for update using ((select public.staff_can('manage_live_requests'))) with check ((select public.staff_can('manage_live_requests')));
-- ---- manage_coins
drop policy if exists "Granted manage_coins: select gifts" on public.gifts;
create policy "Granted manage_coins: select gifts" on public.gifts for select using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: insert gifts" on public.gifts;
create policy "Granted manage_coins: insert gifts" on public.gifts for insert with check ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: update gifts" on public.gifts;
create policy "Granted manage_coins: update gifts" on public.gifts for update using ((select public.staff_can('manage_coins'))) with check ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: delete gifts" on public.gifts;
create policy "Granted manage_coins: delete gifts" on public.gifts for delete using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: select coin_packages" on public.coin_packages;
create policy "Granted manage_coins: select coin_packages" on public.coin_packages for select using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: insert coin_packages" on public.coin_packages;
create policy "Granted manage_coins: insert coin_packages" on public.coin_packages for insert with check ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: update coin_packages" on public.coin_packages;
create policy "Granted manage_coins: update coin_packages" on public.coin_packages for update using ((select public.staff_can('manage_coins'))) with check ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: delete coin_packages" on public.coin_packages;
create policy "Granted manage_coins: delete coin_packages" on public.coin_packages for delete using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: insert store_items" on public.store_items;
create policy "Granted manage_coins: insert store_items" on public.store_items for insert with check ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: update store_items" on public.store_items;
create policy "Granted manage_coins: update store_items" on public.store_items for update using ((select public.staff_can('manage_coins'))) with check ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: delete store_items" on public.store_items;
create policy "Granted manage_coins: delete store_items" on public.store_items for delete using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: select offline_coin_sellers" on public.offline_coin_sellers;
create policy "Granted manage_coins: select offline_coin_sellers" on public.offline_coin_sellers for select using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: insert offline_coin_sellers" on public.offline_coin_sellers;
create policy "Granted manage_coins: insert offline_coin_sellers" on public.offline_coin_sellers for insert with check ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: update offline_coin_sellers" on public.offline_coin_sellers;
create policy "Granted manage_coins: update offline_coin_sellers" on public.offline_coin_sellers for update using ((select public.staff_can('manage_coins'))) with check ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: delete offline_coin_sellers" on public.offline_coin_sellers;
create policy "Granted manage_coins: delete offline_coin_sellers" on public.offline_coin_sellers for delete using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: select lucky_ids" on public.lucky_ids;
create policy "Granted manage_coins: select lucky_ids" on public.lucky_ids for select using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: select gift_transactions" on public.gift_transactions;
create policy "Granted manage_coins: select gift_transactions" on public.gift_transactions for select using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: select coin_purchases" on public.coin_purchases;
create policy "Granted manage_coins: select coin_purchases" on public.coin_purchases for select using ((select public.staff_can('manage_coins')));
drop policy if exists "Granted manage_coins: select wallet_ledger" on public.wallet_ledger;
create policy "Granted manage_coins: select wallet_ledger" on public.wallet_ledger for select using ((select public.staff_can('manage_coins')));
-- ---- manage_agencies
drop policy if exists "Granted manage_agencies: insert agencies" on public.agencies;
create policy "Granted manage_agencies: insert agencies" on public.agencies for insert with check ((select public.staff_can('manage_agencies')));
drop policy if exists "Granted manage_agencies: update agencies" on public.agencies;
create policy "Granted manage_agencies: update agencies" on public.agencies for update using ((select public.staff_can('manage_agencies'))) with check ((select public.staff_can('manage_agencies')));
drop policy if exists "Granted manage_agencies: delete agencies" on public.agencies;
create policy "Granted manage_agencies: delete agencies" on public.agencies for delete using ((select public.staff_can('manage_agencies')));
drop policy if exists "Granted manage_agencies: insert commission_plans" on public.commission_plans;
create policy "Granted manage_agencies: insert commission_plans" on public.commission_plans for insert with check ((select public.staff_can('manage_agencies')));
drop policy if exists "Granted manage_agencies: update commission_plans" on public.commission_plans;
create policy "Granted manage_agencies: update commission_plans" on public.commission_plans for update using ((select public.staff_can('manage_agencies'))) with check ((select public.staff_can('manage_agencies')));
drop policy if exists "Granted manage_agencies: update transfer_requests" on public.transfer_requests;
create policy "Granted manage_agencies: update transfer_requests" on public.transfer_requests for update using ((select public.staff_can('manage_agencies'))) with check ((select public.staff_can('manage_agencies')));
-- ---- view_reports
drop policy if exists "Granted view_reports: select gift_transactions" on public.gift_transactions;
create policy "Granted view_reports: select gift_transactions" on public.gift_transactions for select using ((select public.staff_can('view_reports')));
drop policy if exists "Granted view_reports: select coin_purchases" on public.coin_purchases;
create policy "Granted view_reports: select coin_purchases" on public.coin_purchases for select using ((select public.staff_can('view_reports')));

-- ---- function gates: the first role check becomes staff_can(key) (require_capability(key) still runs after it)
-- decide_transfer_request
CREATE OR REPLACE FUNCTION public.decide_transfer_request(p_request_id uuid, p_approve boolean)
 RETURNS transfer_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.transfer_requests;
begin
  if not public.staff_can('manage_agencies') then
    raise exception 'Only admins can decide transfer requests';
  end if;
  perform public.require_capability('manage_agencies');

  select * into v_row from public.transfer_requests where id = p_request_id and status = 'pending';
  if v_row.id is null then
    raise exception 'Transfer request not found or already decided';
  end if;

  if p_approve then
    update public.transfer_requests set status = 'approved', decided_by = auth.uid(), decided_at = now()
      where id = p_request_id returning * into v_row;

    if v_row.subject_type = 'host' then
      update public.host_profiles set agency_id = v_row.to_agency_id where profile_id = v_row.subject_id;
    else
      update public.staff_roles set agency_id = v_row.to_agency_id where user_id = v_row.subject_id;
    end if;
  else
    update public.transfer_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now()
      where id = p_request_id returning * into v_row;
  end if;

  return v_row;
end;
$function$;

-- admin_save_lucky_id
CREATE OR REPLACE FUNCTION public.admin_save_lucky_id(p_id uuid, p_number text, p_price integer, p_days integer, p_status text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
  v_cur public.lucky_ids%rowtype;
  v_text text := btrim(coalesce(p_number, ''));
  v_num bigint;
  v_digits smallint;
begin
  if not public.staff_can('manage_coins') then
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
$function$;

-- admin_delete_lucky_id
CREATE OR REPLACE FUNCTION public.admin_delete_lucky_id(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.staff_can('manage_coins') then
    raise exception 'Only a Master or Super Admin can manage Lucky IDs';
  end if;
  perform public.require_capability('manage_coins');
  if exists (select 1 from public.lucky_ids where id = p_id and owner_id is not null) then
    raise exception 'Revoke the Lucky ID from its owner first';
  end if;
  delete from public.lucky_ids where id = p_id;
end;
$function$;

-- decide_live_request
CREATE OR REPLACE FUNCTION public.decide_live_request(p_id uuid, p_approve boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_request public.live_requests;
  v_allowed boolean;
begin
  select * into v_request from public.live_requests where id = p_id;
  if v_request.id is null then
    raise exception 'Request not found';
  end if;

  -- agency_id first (every new request has it); host_profiles-derived
  -- fallback for rows that predate this migration and never got one.
  v_allowed := public.staff_can('manage_live_requests')
    or (v_request.agency_id is not null and public.manages_agency(v_request.agency_id))
    or exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = v_request.host_id and public.manages_agency(hp.agency_id)
    );
  if not v_allowed then
    raise exception 'Not allowed to review this request';
  end if;

  update public.live_requests
    set status = case when p_approve then 'approved' else 'rejected' end,
        reviewed_by = auth.uid(),
        reviewed_at = now()
  where id = p_id;

  if p_approve and v_request.type = 'go_live_approval' and v_request.agency_id is not null then
    -- Only create host_profiles if this host doesn't already belong to an
    -- agency — approving a go-live request isn't meant to silently
    -- reassign an existing host to a different agency.
    insert into public.host_profiles (profile_id, agency_id)
    values (v_request.host_id, v_request.agency_id)
    on conflict (profile_id) do nothing;

    insert into public.host_grants (profile_id, agency_id, granted_by, code_id)
    values (v_request.host_id, v_request.agency_id, auth.uid(), null);

    perform public.sync_host_flag(v_request.host_id);
  end if;
end;
$function$;

