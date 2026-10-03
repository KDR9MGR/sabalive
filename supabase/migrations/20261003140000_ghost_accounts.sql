-- Ghost IDs: accounts that can sign in to the app and sit in any live room to
-- watch, without anyone being able to find them or the room being told. For
-- monitoring only. Super Admin creates and manages them; Super Admin and Master
-- (admin) can also watch any live straight from the panel, the same invisible way.
--
-- What "invisible" means here, layer by layer:
--   * The profile is hidden from every other signed-in user (RLS on profiles), so
--     search, follower lists, host cards, leaderboards and profile pages never
--     return it. Only the ghost itself and a Super Admin can read it.
--   * join_live_stream() leaves no live_stream_viewers row, so the ghost is not in
--     "watching now", not in the viewer count, and no "joined" chat line or entry
--     effect plays. (leave_live_stream / heartbeat_viewer then find nothing to do.)
--     Agora itself never announces audience-role joins to a room.
--   * A ghost is view-only: triggers refuse everything it could write that would
--     reveal it — chat, seats, likes, follows, gifts, DMs, calls, going live.
--   * A ghost is never turned away from a room (bans / host blocks are skipped),
--     and signing in on a second device doesn't sign the first one out.
--
-- A ghost is made by the `ghost-admin` Edge Function (Super Admin only), which
-- creates the auth user with app_metadata.ghost = true. app_metadata can only be
-- set server-side, so nobody can turn themselves into one (or hide themselves) by
-- signing up with crafted metadata; the new-user trigger copies the flag onto the
-- profile the moment it exists, so there is no window where a ghost is visible.

-- ---------------------------------------------------------------------------
-- 1. Flag + helpers
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists is_ghost boolean not null default false;
create index if not exists profiles_is_ghost_idx on public.profiles (id) where is_ghost;

create or replace function public.is_ghost(p_user uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select p.is_ghost from public.profiles p where p.id = p_user), false);
$$;
-- Deliberately NOT executable by app users: being able to ask "is this id a ghost?"
-- would defeat the hiding. Triggers and RPCs are security definer and still call it.
revoke execute on function public.is_ghost(uuid) from public, anon, authenticated;
grant execute on function public.is_ghost(uuid) to service_role;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name, username, phone, location, is_ghost)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', 'New Star'),
    coalesce(new.raw_user_meta_data ->> 'username', 'user_' || substr(new.id::text, 1, 8)),
    new.raw_user_meta_data ->> 'phone',
    coalesce(new.raw_user_meta_data ->> 'location', 'India'),
    -- app_metadata is server-controlled; user_metadata (signUp's `data`) is not
    coalesce((new.raw_app_meta_data ->> 'ghost') = 'true', false)
  );
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Ghost accounts + the watch log
-- ---------------------------------------------------------------------------
create table public.ghost_accounts (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  -- what the Super Admin calls it ("Mumbai monitor 1"); never shown in the app
  label text not null check (length(trim(label)) > 0),
  -- the address it signs in with, so the Super Admin can see it again later
  login_email text,
  notes text not null default '',
  -- off = the sign-in is blocked (the Edge Function also bans the auth user)
  active boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  last_watched_at timestamptz
);

-- One row each time a ghost (from the app) or a Super Admin / Master (from the
-- panel) starts watching a live. Who watched what, and when.
create table public.ghost_watch_log (
  id bigint generated always as identity primary key,
  watcher_id uuid not null references public.profiles (id) on delete cascade,
  via text not null check (via in ('app', 'panel')),
  live_stream_id uuid references public.live_streams (id) on delete set null,
  host_id uuid references public.profiles (id) on delete set null,
  started_at timestamptz not null default now()
);
create index ghost_watch_log_started_idx on public.ghost_watch_log (started_at desc);
create index ghost_watch_log_watcher_idx on public.ghost_watch_log (watcher_id, started_at desc);

alter table public.ghost_accounts enable row level security;
alter table public.ghost_watch_log enable row level security;

-- Super Admin reads; nobody writes directly (the RPCs / Edge Function below do)
create policy "Super admin reads ghost accounts"
  on public.ghost_accounts for select using (public.is_super_admin());
create policy "Super admin reads the ghost watch log"
  on public.ghost_watch_log for select using (public.is_super_admin());

-- ---------------------------------------------------------------------------
-- 3. Hide ghost profiles from everyone but the ghost itself and a Super Admin
-- ---------------------------------------------------------------------------
drop policy "Profiles are viewable by everyone" on public.profiles;
create policy "Profiles are viewable except ghosts"
  on public.profiles for select
  using (not is_ghost or id = auth.uid() or public.is_super_admin());

-- ---------------------------------------------------------------------------
-- 4. Registering a ghost (called by the ghost-admin Edge Function, service role)
-- ---------------------------------------------------------------------------
create or replace function public.register_ghost_account(
  p_actor uuid, p_user uuid, p_label text, p_notes text default '', p_login_email text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.staff_roles where user_id = p_actor and role = 'super_admin') then
    raise exception 'Only a Super Admin can create ghost accounts';
  end if;
  if not public.is_ghost(p_user) then
    raise exception 'That account was not created as a ghost';
  end if;
  insert into public.ghost_accounts (profile_id, label, notes, login_email, created_by)
  values (p_user, trim(p_label), coalesce(p_notes, ''), nullif(trim(p_login_email), ''), p_actor);
  insert into public.audit_logs (actor_id, action, target, severity)
  values (p_actor, 'ghost.created', trim(p_label), 'warning');
end;
$$;
revoke execute on function public.register_ghost_account(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.register_ghost_account(uuid, uuid, text, text, text) to service_role;

-- Super Admin edits label / notes / on-off from the panel. (Turning one off also
-- bans the auth user — that part needs the service role, so the panel does both
-- through the Edge Function; this RPC only keeps the row in step.)
create or replace function public.update_ghost_account(
  p_user uuid, p_label text, p_notes text, p_active boolean
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Only a Super Admin can manage ghost accounts';
  end if;
  update public.ghost_accounts
     set label = coalesce(nullif(trim(p_label), ''), label),
         notes = coalesce(p_notes, notes),
         active = coalesce(p_active, active)
   where profile_id = p_user;
  if not found then raise exception 'Ghost account not found'; end if;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'ghost.updated', p_user::text, 'info');
end;
$$;
revoke execute on function public.update_ghost_account(uuid, text, text, boolean) from public, anon;
grant execute on function public.update_ghost_account(uuid, text, text, boolean) to authenticated;

-- May this staff member watch lives invisibly from the panel? Super Admin always;
-- Master unless a Super Admin switched `monitor_lives` off for that account (the
-- permission is on by default for a Master, so only an explicit false blocks).
create or replace function public.staff_can_ghost_watch()
returns boolean
language sql stable security definer set search_path = public
as $$
  select case public.current_staff_role()
    when 'super_admin' then true
    when 'admin' then coalesce(
      nullif((select s.permissions ->> 'monitor_lives' from public.staff_roles s where s.user_id = auth.uid()), '')::boolean,
      true)
    else false
  end;
$$;
revoke execute on function public.staff_can_ghost_watch() from public, anon;
grant execute on function public.staff_can_ghost_watch() to authenticated;

-- How may the caller watch a live invisibly? 'ghost' = an active ghost account (in
-- the app), 'staff' = a Super Admin / Master (from the panel), null = not at all.
-- Used by the agora-token Edge Function to decide whether to skip the room checks.
create or replace function public.ghost_watch_mode()
returns text
language sql stable security definer set search_path = public
as $$
  select case
    when exists (select 1 from public.ghost_accounts g where g.profile_id = auth.uid() and g.active) then 'ghost'
    when public.staff_can_ghost_watch() then 'staff'
  end;
$$;
revoke execute on function public.ghost_watch_mode() from public, anon;
grant execute on function public.ghost_watch_mode() to authenticated;

-- The panel's "Watch" button: Super Admin / Master only. Records the watch.
create or replace function public.panel_log_ghost_watch(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.staff_can_ghost_watch() then
    raise exception 'Only a Super Admin or Master can watch a live from the panel';
  end if;
  insert into public.ghost_watch_log (watcher_id, via, live_stream_id, host_id)
  select auth.uid(), 'panel', s.id, s.host_id from public.live_streams s where s.id = p_stream_id;
end;
$$;
revoke execute on function public.panel_log_ghost_watch(uuid) from public, anon;
grant execute on function public.panel_log_ghost_watch(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Joining a live as a ghost leaves no trace in the room
-- ---------------------------------------------------------------------------
create or replace function public.join_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_entry uuid[];
begin
  if auth.uid() is null then
    raise exception 'Must be signed in to join a live stream';
  end if;

  if public.is_ghost(auth.uid()) then
    -- no viewer row (so not listed, not counted), no "joined" line, no entry effect
    insert into public.ghost_watch_log (watcher_id, via, live_stream_id, host_id)
    select auth.uid(), 'app', s.id, s.host_id from public.live_streams s where s.id = p_stream_id;
    update public.ghost_accounts set last_watched_at = now() where profile_id = auth.uid();
    return;
  end if;

  update public.live_stream_viewers
  set left_at = now()
  where live_stream_id = p_stream_id and viewer_id = auth.uid() and left_at is null;
  insert into public.live_stream_viewers (live_stream_id, viewer_id)
  values (p_stream_id, auth.uid());

  select array_agg(ui.item_id order by case si.category when 'vehicle' then 0 else 1 end)
    into v_entry
    from public.user_items ui
    join public.store_items si on si.id = ui.item_id
   where ui.profile_id = auth.uid()
     and ui.equipped
     and ui.expires_at > now()
     and si.status = 'active'
     and si.category in ('entry_effect', 'vehicle');

  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, entry_item_ids)
  values (p_stream_id, auth.uid(), 'joined the live stream', 'system', v_entry);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. A ghost is never turned away from a live; sessions are shared
-- ---------------------------------------------------------------------------
create or replace function public.live_access_denied_reason(p_user uuid, p_stream uuid default null)
returns table (code text, message text)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_until timestamptz;
  v_kind text;
  v_dev text := public.current_device_id();
  v_host uuid;
begin
  if p_user is null then
    return;
  end if;

  -- a ghost account is never turned away from a live (bans, device bans, a host
  -- who removed or blocked them): it exists to watch
  if public.is_ghost(p_user) then
    return;
  end if;

  select b.kind, coalesce(b.ends_at, 'infinity') into v_kind, v_until
    from public.user_bans b
   where b.user_id = p_user and b.kind in ('account', 'live') and public.ban_active(b)
   order by coalesce(b.ends_at, 'infinity') desc
   limit 1;
  if found then
    return query select 'BN001'::text,
      public.ban_message(case v_kind when 'account' then 'Your account is banned' else 'You are banned from live' end, v_until);
    return;
  end if;

  if v_dev is not null then
    select coalesce(b.ends_at, 'infinity') into v_until
      from public.banned_devices bd
      join public.user_bans b on b.id = bd.ban_id
     where bd.device_id = v_dev and public.ban_active(b)
     order by coalesce(b.ends_at, 'infinity') desc
     limit 1;
    if found then
      return query select 'BN001'::text, public.ban_message('This device is banned', v_until);
      return;
    end if;
  end if;

  if p_stream is not null then
    if exists (
      select 1 from public.live_stream_viewer_bans
      where live_stream_id = p_stream and user_id = p_user
    ) then
      return query select 'BN002'::text, 'The host removed you from this live.'::text;
      return;
    end if;
    select host_id into v_host from public.live_streams where id = p_stream;
    if v_host is not null and v_host <> p_user and exists (
      select 1 from public.blocks where blocker_id = v_host and blocked_id = p_user
    ) then
      return query select 'BN002'::text, 'You can''t join this live.'::text;
      return;
    end if;
  end if;
end;
$$;

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

  -- a ghost ID is shared by the staff who use it, so signing in on one device must
  -- not sign the others out
  if public.is_ghost(v_me) then
    return;
  end if;

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

-- ---------------------------------------------------------------------------
-- 7. A ghost is view-only: nothing it could write may reveal it
-- ---------------------------------------------------------------------------
create or replace function public.assert_not_ghost()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- server-side writers (cron, service role) have no signed-in user
  if auth.uid() is null or not public.is_ghost(auth.uid()) then
    return new;
  end if;
  -- opening someone's profile quietly logs nothing, rather than erroring
  if tg_table_name = 'profile_visits' then
    return null;
  end if;
  raise exception 'Ghost accounts are view-only' using errcode = 'GH001';
end;
$$;
revoke execute on function public.assert_not_ghost() from public, anon, authenticated;

do $$
declare
  t text;
begin
  foreach t in array array[
    'live_chat_messages', 'live_stream_seats', 'live_stream_viewers', 'live_streams',
    'stream_likes', 'follows', 'gift_transactions', 'profile_visits',
    'dm_messages', 'conversations', 'conversation_participants', 'calls',
    'blocks', 'user_reports'
  ] loop
    execute format('drop trigger if exists %I on public.%I', t || '_ghost_block', t);
    execute format(
      'create trigger %I before insert on public.%I for each row execute function public.assert_not_ghost()',
      t || '_ghost_block', t
    );
  end loop;
end $$;
