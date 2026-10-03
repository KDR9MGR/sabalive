-- One active session per account, login history, avatar frames that show
-- everywhere, an Event gift category, and no Lucky Box for audio rooms.

-- ---------------------------------------------------------------------------
-- 1. Gifts: an "event" category (its own Event tab in the app's gift sheet)
-- ---------------------------------------------------------------------------
alter table public.gifts drop constraint gifts_category_check;
alter table public.gifts add constraint gifts_category_check
  check (category in ('basic', 'luxury', 'vehicle', 'special', 'event'));

-- ---------------------------------------------------------------------------
-- 2. Lucky Box is for video lives only: audio rooms never earn the reward
-- ---------------------------------------------------------------------------
create or replace function public.grant_lucky_box_rewards()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_duration integer;
  v_reward integer;
begin
  select duration_minutes, reward_diamonds into v_duration, v_reward
  from public.lucky_box_config where id;
  if v_duration is null then return; end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
  select host_id, 'grant', 'diamonds', v_reward, 'live_streams', id, 'lucky_box'
  from public.live_streams
  where status = 'live'
    and mode <> 'audio'
    and started_at <= now() - (v_duration || ' minutes')::interval
    and not exists (
      select 1 from public.wallet_ledger
      where reference_table = 'live_streams'
        and reference_id = live_streams.id
        and note = 'lucky_box'
    );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2b. Everyone who leaves a live shows as "left", as everyone who arrives shows
--     as "joined". A normal exit already posts that line (leave_live_stream); a
--     viewer whose app was killed or lost its connection never said goodbye, so
--     the cleanup that removes them now posts it too.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_stale_presence()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.live_stream_seats where last_heartbeat_at < now() - interval '90 seconds';

  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind)
  select distinct v.live_stream_id, v.viewer_id, 'left the live stream', 'system'
    from public.live_stream_viewers v
    join public.live_streams s on s.id = v.live_stream_id and s.status = 'live'
   where v.left_at is null
     and v.last_heartbeat_at < now() - interval '90 seconds';

  update public.live_stream_viewers set left_at = now()
  where left_at is null and last_heartbeat_at < now() - interval '90 seconds';
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Avatar frames
--
-- Two places can hand a user a frame: the Store (store_items, category 'frame',
-- bought for N days and equipped from the Bag) and the panel's Profile Frame
-- catalog (frames / user_frames: free, level, coins, or granted by an admin).
-- Whichever is equipped, the frame's artwork url is copied onto
-- profiles.frame_url so every screen that already has a profile row can draw it
-- — profile, live top bar, seats — without another query. Only one frame is
-- equipped at a time across both. Clients can't write the column (profiles
-- grants only name / username / bio / location / avatar_url).
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists frame_url text;

create or replace function public.compute_frame_url(p_profile uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select si.asset_url
       from public.user_items ui
       join public.store_items si on si.id = ui.item_id
      where ui.profile_id = p_profile
        and ui.equipped
        and ui.expires_at > now()
        and si.category = 'frame'
        and si.status = 'active'
        and si.asset_url is not null
      order by ui.purchased_at desc
      limit 1),
    (select f.icon_url
       from public.user_frames uf
       join public.frames f on f.id = uf.frame_id
      where uf.profile_id = p_profile
        and uf.equipped
        and f.status = 'active'
        and f.icon_url is not null
      limit 1)
  );
$$;
revoke execute on function public.compute_frame_url(uuid) from public;

create or replace function public.sync_profile_frame(p_profile uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_url text := public.compute_frame_url(p_profile);
begin
  update public.profiles set frame_url = v_url
   where id = p_profile and frame_url is distinct from v_url;
end;
$$;
revoke execute on function public.sync_profile_frame(uuid) from public;

-- Equipping a Store frame unequips any Profile Frame, and the other way round.
create or replace function public.frame_equip_changed()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_profile uuid;
  v_is_frame boolean := true;
begin
  if tg_op = 'DELETE' then
    v_profile := old.profile_id;
  else
    v_profile := new.profile_id;
  end if;

  if tg_table_name = 'user_items' then
    select exists (
      select 1 from public.store_items si
       where si.id = case when tg_op = 'DELETE' then old.item_id else new.item_id end
         and si.category = 'frame'
    ) into v_is_frame;
    if not v_is_frame then
      return null;
    end if;
    if tg_op <> 'DELETE' and new.equipped and pg_trigger_depth() = 1 then
      update public.user_frames set equipped = false
       where profile_id = v_profile and equipped;
    end if;
  elsif tg_table_name = 'user_frames' then
    if tg_op <> 'DELETE' and new.equipped and pg_trigger_depth() = 1 then
      update public.user_items ui set equipped = false
        from public.store_items si
       where ui.profile_id = v_profile and ui.equipped
         and si.id = ui.item_id and si.category = 'frame';
    end if;
  end if;

  perform public.sync_profile_frame(v_profile);
  return null;
end;
$$;
revoke execute on function public.frame_equip_changed() from public;

create trigger user_items_frame_sync
  after insert or update of equipped or delete on public.user_items
  for each row execute function public.frame_equip_changed();
create trigger user_frames_frame_sync
  after insert or update of equipped or delete on public.user_frames
  for each row execute function public.frame_equip_changed();

-- A frame whose artwork the admin replaces (or whose item expires) updates its owners.
create or replace function public.frame_artwork_changed()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  r record;
begin
  if tg_table_name = 'store_items' then
    for r in select distinct profile_id from public.user_items where item_id = new.id and equipped loop
      perform public.sync_profile_frame(r.profile_id);
    end loop;
  else
    for r in select profile_id from public.user_frames where frame_id = new.id and equipped loop
      perform public.sync_profile_frame(r.profile_id);
    end loop;
  end if;
  return null;
end;
$$;
revoke execute on function public.frame_artwork_changed() from public;

create trigger store_items_frame_artwork
  after update of asset_url, status on public.store_items
  for each row when (new.category = 'frame') execute function public.frame_artwork_changed();
create trigger frames_frame_artwork
  after update of icon_url, status on public.frames
  for each row execute function public.frame_artwork_changed();

-- A Store frame that has run out stops showing (the label is only recomputed on
-- change, so a sweep catches expiry).
create or replace function public.refresh_expired_frames()
returns void
language sql security definer set search_path = public
as $$
  update public.profiles p set frame_url = public.compute_frame_url(p.id)
   where p.frame_url is not null
     and p.frame_url is distinct from public.compute_frame_url(p.id);
$$;
revoke execute on function public.refresh_expired_frames() from public;

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'refresh-expired-frames') then
    perform cron.schedule('refresh-expired-frames', '*/10 * * * *', $sql$select public.refresh_expired_frames()$sql$);
  end if;
end;
$outer$;

-- Equip / remove a frame the user owns in the Profile Frame catalog.
create or replace function public.set_frame_equipped(p_frame_id uuid, p_equipped boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  if not exists (
    select 1 from public.user_frames where profile_id = v_me and frame_id = p_frame_id
  ) then
    raise exception 'You do not own this frame';
  end if;
  if p_equipped then
    update public.user_frames set equipped = false
     where profile_id = v_me and equipped and frame_id <> p_frame_id;
  end if;
  update public.user_frames set equipped = p_equipped
   where profile_id = v_me and frame_id = p_frame_id;
end;
$$;
revoke execute on function public.set_frame_equipped(uuid, boolean) from public;
grant execute on function public.set_frame_equipped(uuid, boolean) to authenticated;

-- Get a frame from the Profile Frame catalog by its unlock rule: free, a level, or
-- coins. VIP and event frames are given out by an admin, so they are not claimable.
create or replace function public.claim_frame(p_frame_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_frame public.frames%rowtype;
  v_level integer;
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  select * into v_frame from public.frames where id = p_frame_id and status = 'active';
  if not found then
    raise exception 'Frame not found';
  end if;
  if exists (select 1 from public.user_frames where profile_id = v_me and frame_id = p_frame_id) then
    return;
  end if;

  if v_frame.unlock_type = 'free' then
    null;
  elsif v_frame.unlock_type = 'level' then
    select level into v_level from public.profiles where id = v_me;
    if coalesce(v_level, 0) < v_frame.unlock_value then
      raise exception 'Reach level % to unlock this frame', v_frame.unlock_value;
    end if;
  elsif v_frame.unlock_type = 'coins' then
    if v_frame.price_coins <= 0 then
      raise exception 'This frame has no price set';
    end if;
    if (select coins from public.wallets where profile_id = v_me) < v_frame.price_coins then
      raise exception 'Insufficient coins';
    end if;
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (v_me, 'store_purchase', 'coins', -v_frame.price_coins, 'frames', 'Unlocked ' || v_frame.name);
  else
    raise exception 'This frame is given out by the team';
  end if;

  insert into public.user_frames (profile_id, frame_id) values (v_me, p_frame_id);
end;
$$;
revoke execute on function public.claim_frame(uuid) from public;
grant execute on function public.claim_frame(uuid) to authenticated;

-- Frames already equipped today get their url now.
update public.profiles p set frame_url = public.compute_frame_url(p.id)
 where exists (select 1 from public.user_frames uf where uf.profile_id = p.id and uf.equipped)
    or exists (select 1 from public.user_items ui where ui.profile_id = p.id and ui.equipped);

-- ---------------------------------------------------------------------------
-- 4. One active session per account + login history
-- ---------------------------------------------------------------------------
-- The device that signed in last holds the session; the app signing in on
-- another device signs the earlier one out at once (it watches this row), and the
-- earlier session is deleted so it can't refresh.
create table public.user_active_session (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  session_id uuid,
  device_id text,
  platform text,
  model text,
  signed_in_at timestamptz not null default now()
);

create table public.user_login_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- how they signed in: email, phone_otp, google, apple, facebook, signup
  method text not null,
  device_id text,
  platform text,
  model text,
  ip text,
  created_at timestamptz not null default now()
);
create index user_login_events_user_idx on public.user_login_events (user_id, created_at desc);

alter table public.user_active_session enable row level security;
alter table public.user_login_events enable row level security;

create policy "Users see their own active session"
  on public.user_active_session for select using (user_id = auth.uid());
create policy "Users and admins see login history"
  on public.user_login_events for select
  using (user_id = auth.uid() or public.is_admin_or_above());

alter publication supabase_realtime add table public.user_active_session;

create or replace function public.claim_session(
  p_method text,
  p_device_id text default null,
  p_platform text default null,
  p_model text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_sid uuid;
  v_device text := coalesce(nullif(trim(p_device_id), ''), public.current_device_id());
  v_ip text;
begin
  if v_me is null then
    raise exception 'Must be signed in';
  end if;
  begin
    v_sid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  exception when others then
    v_sid := null;
  end;
  v_ip := nullif(trim(split_part(
    coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1
  )), '');

  insert into public.user_login_events (user_id, method, device_id, platform, model, ip)
  values (v_me, coalesce(nullif(trim(p_method), ''), 'unknown'), v_device, p_platform, p_model, v_ip);

  insert into public.user_active_session (user_id, session_id, device_id, platform, model)
  values (v_me, v_sid, v_device, p_platform, p_model)
  on conflict (user_id) do update
    set session_id = excluded.session_id,
        device_id = excluded.device_id,
        platform = excluded.platform,
        model = excluded.model,
        signed_in_at = now();

  if v_sid is not null then
    delete from auth.sessions where user_id = v_me and id <> v_sid;
  end if;
end;
$$;
revoke execute on function public.claim_session(text, text, text, text) from public;
grant execute on function public.claim_session(text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Panel: how a user signs in, and which devices they use
-- ---------------------------------------------------------------------------
create or replace function public.admin_user_login_info(p_user uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_user auth.users%rowtype;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can view login details';
  end if;
  perform public.require_capability('manage_users');

  select * into v_user from auth.users where id = p_user;
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'email', v_user.email,
    'phone', v_user.phone,
    'created_at', v_user.created_at,
    'last_sign_in_at', v_user.last_sign_in_at,
    'email_confirmed_at', v_user.email_confirmed_at,
    'banned_until', v_user.banned_until,
    'providers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'provider', i.provider,
               'created_at', i.created_at,
               'last_sign_in_at', i.last_sign_in_at)
             order by i.created_at)
        from auth.identities i where i.user_id = p_user
    ), '[]'::jsonb),
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object(
               'device_id', d.device_id,
               'platform', d.platform,
               'model', d.model,
               'first_seen_at', d.first_seen_at,
               'last_seen_at', d.last_seen_at)
             order by d.last_seen_at desc)
        from public.user_devices d where d.user_id = p_user
    ), '[]'::jsonb),
    'logins', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.created_at desc)
        from (
          select method, device_id, platform, model, ip, created_at
            from public.user_login_events
           where user_id = p_user
           order by created_at desc
           limit 20
        ) e
    ), '[]'::jsonb),
    'active_session', (
      select jsonb_build_object(
               'device_id', s.device_id, 'platform', s.platform,
               'model', s.model, 'signed_in_at', s.signed_in_at)
        from public.user_active_session s where s.user_id = p_user
    )
  );
end;
$$;
revoke execute on function public.admin_user_login_info(uuid) from public;
grant execute on function public.admin_user_login_info(uuid) to authenticated;
