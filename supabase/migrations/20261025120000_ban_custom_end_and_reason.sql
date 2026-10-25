-- Bans: a 24 hour option, a custom end date, and the reason shown to the banned person when they try to sign in.
--
-- 1. ban_user_v2(user, kinds, duration, reason, ends_at): the same ban as ban_user (20261006100000) with two more durations. '24h' and '7d' / '30d' are
--    worked out on the SERVER clock; 'custom' takes p_ends_at (more than 5 minutes ahead, at most 10 years: use 'permanent' beyond that); 'permanent'
--    has no end. ban_user stays untouched for anything still calling it (set_profile_status calls it with 'permanent').
-- 2. user_bans.reason_visible: a reason typed through ban_user_v2 is meant for the user and is marked visible. Reasons of bans placed before this
--    migration were written as staff-only notes and stay hidden (default false), so nobody suddenly sees an old internal note.
-- 3. check_login_access_v2(devices, email, phone): callable BEFORE sign-in (anon). Says whether the account behind that email / phone has an ID ban,
--    whether one of the phone's ids is banned, or whether the email / phone is on the blocklist, with the end date and (only if marked visible) the
--    reason, so the app can show them instead of a bare "This account has been banned.". It returns nothing for an account that is not banned.
--
-- Additive: one column with a constant default (no table rewrite), two new functions. Rollback: supabase/rollbacks/20261025120000_down.sql.
alter table public.user_bans add column if not exists reason_visible boolean not null default false;

create or replace function public.ban_user_v2(
  p_user uuid, p_kinds text[], p_duration text, p_reason text default null, p_ends_at timestamptz default null
)
returns setof public.user_bans
language plpgsql security definer set search_path = public
as $$
declare
  v_kind text;
  v_kinds text[];
  v_ends timestamptz;
  v_reason text := nullif(trim(p_reason), '');
  v_label text;
  v_ban public.user_bans;
begin
  if not public.staff_can('manage_users') then
    raise exception 'Only admins can ban users';
  end if;
  perform public.require_capability('manage_users');
  if p_user = auth.uid() then
    raise exception 'You can''t ban yourself';
  end if;
  if exists (select 1 from public.staff_roles where user_id = p_user) then
    raise exception 'Staff accounts can''t be banned here';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'User not found';
  end if;
  if p_duration is null or p_duration not in ('24h', '7d', '30d', 'custom', 'permanent') then
    raise exception 'Duration must be 24h, 7d, 30d, custom or permanent';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'Keep the reason under 500 characters';
  end if;
  select array_agg(distinct k) into v_kinds from unnest(p_kinds) k;
  if v_kinds is null or not (v_kinds <@ array['live', 'account', 'device']) then
    raise exception 'Choose at least one of: live, account, device';
  end if;

  if p_duration = 'custom' then
    if p_ends_at is null then raise exception 'Pick the date the ban ends'; end if;
    if p_ends_at <= now() + interval '5 minutes' then raise exception 'The end date must be in the future'; end if;
    if p_ends_at > now() + interval '10 years' then raise exception 'The end date can be at most 10 years away: choose Permanent for longer'; end if;
  end if;
  v_ends := case p_duration
    when '24h' then now() + interval '24 hours'
    when '7d' then now() + interval '7 days'
    when '30d' then now() + interval '30 days'
    when 'custom' then p_ends_at
    else null
  end;
  v_label := case when p_duration = 'custom' then 'until ' || to_char(v_ends at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' else p_duration end;

  foreach v_kind in array v_kinds loop
    update public.user_bans
       set lifted_at = now(), lifted_by = auth.uid(), lift_note = 'Replaced by a new ban'
     where user_id = p_user and kind = v_kind and public.ban_active(user_bans);

    insert into public.user_bans (user_id, kind, ends_at, reason, reason_visible, created_by)
    values (p_user, v_kind, v_ends, v_reason, v_reason is not null, auth.uid())
    returning * into v_ban;

    -- an ID ban and a device ban both cover every device the user has used
    if v_kind in ('account', 'device') then
      insert into public.banned_devices (device_id, ban_id)
      select device_id, v_ban.id from public.user_devices where user_id = p_user
      on conflict do nothing;
    end if;

    return next v_ban;
  end loop;

  -- get them out of any live right now
  if v_kinds && array['live', 'account'] then
    update public.live_streams set status = 'ended', ended_at = now()
     where host_id = p_user and status = 'live';
    update public.live_stream_viewers set left_at = now()
     where viewer_id = p_user and left_at is null;
    delete from public.live_stream_seats where occupant_id = p_user;
  end if;

  if 'account' = any (v_kinds) then
    perform public.sync_account_ban(p_user);
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.banned', p_user::text || ' -> ' || array_to_string(v_kinds, '+') || ' for ' || v_label, 'warning');
end;
$$;
revoke execute on function public.ban_user_v2(uuid, text[], text, text, timestamptz) from public, anon;
grant execute on function public.ban_user_v2(uuid, text[], text, text, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Before sign-in: is this person banned, until when, and (if staff marked it visible) why
-- ---------------------------------------------------------------------------
-- {"banned": false} or {"banned": true, "kind": "account"|"device"|"identity", "until": timestamp|null, "permanent": bool, "note": text|null}.
-- An ID ban beats a device ban, which beats an identity block; within one kind the ban that lasts longest is the one described.
create or replace function public.check_login_access_v2(
  p_device_ids text[] default '{}', p_email text default null, p_phone text default null
)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_digits text := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), '');
  v_user uuid;
  v_ends timestamptz;
  v_note text;
  v_found boolean := false;
begin
  -- 1. the account behind this email / phone number has an ID ban
  if v_email is not null then
    select u.id into v_user from auth.users u where lower(u.email) = v_email limit 1;
  end if;
  if v_user is null and v_digits is not null then
    select u.id into v_user from auth.users u where u.phone in (v_digits, '+' || v_digits) limit 1;
  end if;
  if v_user is not null then
    select true, b.ends_at, case when b.reason_visible then b.reason end into v_found, v_ends, v_note
      from public.user_bans b
     where b.user_id = v_user and b.kind = 'account' and public.ban_active(b)
     order by coalesce(b.ends_at, 'infinity'::timestamptz) desc, b.created_at desc
     limit 1;
    if v_found then
      return jsonb_build_object('banned', true, 'kind', 'account', 'until', v_ends, 'permanent', v_ends is null, 'note', v_note);
    end if;
  end if;

  -- 2. one of this phone's ids is banned
  select true, b.ends_at, case when b.reason_visible then b.reason end into v_found, v_ends, v_note
    from public.banned_devices bd
    join public.user_bans b on b.id = bd.ban_id
   where bd.device_id = any (coalesce(p_device_ids, '{}')) and public.ban_active(b)
   order by coalesce(b.ends_at, 'infinity'::timestamptz) desc, b.created_at desc
   limit 1;
  if v_found then
    return jsonb_build_object('banned', true, 'kind', 'device', 'until', v_ends, 'permanent', v_ends is null, 'note', v_note);
  end if;

  -- 3. the email / phone number is on the blocklist an ID or device ban leaves behind
  select true, i.ends_at, case when b.reason_visible then b.reason end into v_found, v_ends, v_note
    from public.banned_identities i
    left join public.user_bans b on b.id = i.ban_id
   where i.lifted_at is null and (i.ends_at is null or i.ends_at > now())
     and ((i.kind = 'email' and i.value = public.normalize_identity('email', p_email))
       or (i.kind = 'phone' and i.value = public.normalize_identity('phone', p_phone)))
   order by coalesce(i.ends_at, 'infinity'::timestamptz) desc, i.created_at desc
   limit 1;
  if v_found then
    return jsonb_build_object('banned', true, 'kind', 'identity', 'until', v_ends, 'permanent', v_ends is null, 'note', v_note);
  end if;

  return jsonb_build_object('banned', false);
end;
$$;
revoke execute on function public.check_login_access_v2(text[], text, text) from public;
grant execute on function public.check_login_access_v2(text[], text, text) to anon, authenticated;
