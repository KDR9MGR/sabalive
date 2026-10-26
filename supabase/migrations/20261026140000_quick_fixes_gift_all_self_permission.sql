-- Quick fixes: Send to All includes the sender; the diamond reset is a permission; SVG / SVGA uploads for banners.
--
-- 1. send_gift_to_all_v3(gift, live, quantity): "Send to All" now also reaches the SENDER when they are the host or sit on a seat (the gift sheet already listed them;
--    v2 left them out). Everything else is exactly v2: charged up front (price x people x quantity), one ledger / gift row per person and unit, ONE chat line
--    "sent 10x Rose to 5 people", the recipients recorded for the sound rule. A sender who is only a viewer is not among the people (as before). v2 stays untouched for
--    old app builds, which keep leaving the sender out; the new app calls v3 and falls back to v2 while this migration is missing.
--    Rollback: supabase/rollbacks/20261026140000_down.sql.
-- 2. The diamond reset (20261026120000 / 20261026130000) becomes a permission of its own, reset_diamonds, on the Access Control page: on by default for a Master, an explicit
--    false blocks it, a Super Admin always has it, and nobody below Master ever can (the functions still require is_admin_or_above()). _diamond_reset_actor_ok() now
--    reads it instead of run_payroll, and set_staff_permissions accepts the key (the same function as before with one more known key and the "a Master can only give what
--    they hold" rule for it).
-- 3. The banners bucket also accepts GIF and the generic binary type, so an SVG / SVGA file (sent as application/octet-stream, like SVGA already is for the gift-assets
--    bucket) can be uploaded as a banner too. Nothing else about the bucket changes (5 MB limit, public read).
--
-- Additive except two replaced functions (_diamond_reset_actor_ok, set_staff_permissions) whose old definitions are in the rollback.

-- ---------------------------------------------------------------------------------- 1
create or replace function public.send_gift_to_all_v3(p_gift_id uuid, p_live_stream_id uuid, p_quantity integer default 1)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_qty integer := coalesce(p_quantity, 1);
  v_price integer;
  v_gift_name text;
  v_gift_emoji text;
  v_host uuid;
  v_status text;
  v_recipients uuid[];
  v_n integer;
  v_receiver uuid;
  v_i integer;
begin
  if v_sender is null then
    raise exception 'Must be signed in to send a gift';
  end if;
  if v_qty < 1 or v_qty > 99 then
    raise exception 'Pick a quantity from 1 to 99';
  end if;

  select host_id, status into v_host, v_status from public.live_streams where id = p_live_stream_id;
  if v_host is null then
    raise exception 'This live no longer exists';
  end if;
  if v_status is distinct from 'live' then
    raise exception 'This live has ended';
  end if;

  select price_coins, name, emoji into v_price, v_gift_name, v_gift_emoji
    from public.gifts where id = p_gift_id and status = 'active';
  if v_price is null then
    raise exception 'Unknown or inactive gift';
  end if;

  -- everyone worth gifting: the host and whoever is on a seat, THE SENDER INCLUDED when they are one of them (v2 left the sender out)
  select array_agg(r.id) into v_recipients
    from (
      select v_host as id
      union
      select s.occupant_id from public.live_stream_seats s where s.live_stream_id = p_live_stream_id
    ) r;
  v_n := coalesce(cardinality(v_recipients), 0);
  if v_n = 0 then
    raise exception 'There is no one here to send this to';
  end if;

  if coalesce((select coins from public.wallets where profile_id = v_sender), 0) < v_price::bigint * v_n * v_qty then
    raise exception 'Insufficient coins';
  end if;

  foreach v_receiver in array v_recipients loop
    for v_i in 1..v_qty loop
      insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
        values (v_sender, 'gift_sent', 'coins', -v_price, 'gift_transactions', 'Gift sent');
      insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
        values (v_receiver, 'gift_received', 'diamonds', v_price, 'gift_transactions', 'Gift received');
      insert into public.gift_transactions (live_stream_id, sender_id, receiver_id, gift_id, coins)
        values (p_live_stream_id, v_sender, v_receiver, p_gift_id, v_price);
    end loop;
  end loop;

  update public.live_streams set gift_coin_total = gift_coin_total + v_price::bigint * v_n * v_qty
   where id = p_live_stream_id;

  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, gift_id, to_all, gift_count, gift_receiver_ids)
    values (p_live_stream_id, v_sender,
            'sent ' || v_qty || 'x ' || v_gift_name || ' ' || v_gift_emoji || ' to ' || v_n || case when v_n = 1 then ' person' else ' people' end,
            'gift', p_gift_id, true, v_qty, v_recipients);

  return v_n;
end;
$$;
revoke execute on function public.send_gift_to_all_v3(uuid, uuid, integer) from public, anon;
grant execute on function public.send_gift_to_all_v3(uuid, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------------- 2
create or replace function public._diamond_reset_actor_ok()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.is_admin_or_above() and public.staff_cap_on('reset_diamonds');
$$;
revoke execute on function public._diamond_reset_actor_ok() from public, anon, authenticated;

-- Access Control accepts the key
CREATE OR REPLACE FUNCTION public.set_staff_permissions(p_user_id uuid, p_permissions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_actor_role public.staff_role := public.current_staff_role();
  v_target_role public.staff_role;
  v_old jsonb;
  v_perms jsonb := coalesce(p_permissions, '{}'::jsonb);
  v_known text[] := array[
    'view_dashboards', 'manage_users', 'view_user_profile', 'manage_admins', 'manage_agencies', 'manage_hosts', 'manage_coins',
    'run_payroll', 'edit_config', 'manage_infra', 'view_audit', 'impersonate', 'export_data', 'view_reports',
    'manage_live_requests', 'manage_lucky_box', 'manage_badges', 'manage_leaderboard_frame',
    'manage_profile_frames', 'manage_content', 'manage_system', 'monitor_lives', 'manage_levels', 'manage_support',
    'manage_tags', 'reset_diamonds'
  ];
  k text;
  v jsonb;
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  if v_actor_role is null or v_actor_role not in ('super_admin', 'admin') then
    raise exception 'Only a Super Admin or a Master can change an account''s permissions';
  end if;
  if p_user_id = v_actor then raise exception 'You cannot change your own permissions'; end if;

  select role, permissions into v_target_role, v_old from public.staff_roles where user_id = p_user_id;
  if v_target_role is null then raise exception 'That account has no staff role'; end if;
  if v_target_role = 'super_admin' then raise exception 'A Super Admin always has full access'; end if;
  if v_actor_role = 'admin' and not public.can_manage_staff_role('admin', v_target_role) then
    raise exception 'A Master can only change permissions of accounts below Master';
  end if;

  if jsonb_typeof(v_perms) <> 'object' then raise exception 'Permissions must be an object'; end if;
  for k, v in select * from jsonb_each(v_perms) loop
    if not (k = any (v_known)) then raise exception 'Unknown permission %', k; end if;
    if jsonb_typeof(v) <> 'boolean' then raise exception 'Permission % must be true or false', k; end if;
    -- a Master cannot give what they do not hold themselves
    if v_actor_role = 'admin' and v = 'true'::jsonb and coalesce(v_old ->> k, '') <> 'true' then
      if k = 'monitor_lives' then
        if not public.staff_can_ghost_watch() then raise exception 'You do not have "%" yourself, so you cannot give it', k; end if;
      elsif k = 'manage_tags' then
        if not public.staff_can_manage_tags() then raise exception 'You do not have "%" yourself, so you cannot give it', k; end if;
      elsif k in ('manage_levels', 'manage_support', 'view_user_profile', 'reset_diamonds') then
        if not public.staff_cap_on(k) then raise exception 'You do not have "%" yourself, so you cannot give it', k; end if;
      elsif not public.has_capability(k) then
        raise exception 'You do not have "%" yourself, so you cannot give it', k;
      end if;
    end if;
  end loop;

  update public.staff_roles set permissions = v_perms where user_id = p_user_id;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (v_actor, 'staff.permissions_changed', p_user_id::text || ' (' || v_target_role::text || ') ' || v_perms::text, 'warning');

  return v_perms;
end;
$function$;

-- ---------------------------------------------------------------------------------- 3
update storage.buckets
   set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/octet-stream']
 where id = 'banners';
