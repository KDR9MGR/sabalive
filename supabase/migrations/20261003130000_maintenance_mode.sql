-- Maintenance mode and emergency lockdown, controlled by the Super Admin.
--
--   online       everything normal
--   maintenance  scheduled or manual: a countdown to the end time, app users (and
--                optionally panel staff) are locked out
--   lockdown     emergency: no timer, everyone but the Super Admin is locked out
--
-- Enforced here, not only in the apps: a PostgREST pre-request function
-- (maintenance_gate) runs before every API request and refuses it with HTTP 503
-- "MAINTENANCE_MODE" while the system is locked, so an old app, a cached screen
-- or a direct API call can't get around it. The Super Admin is always exempt (so
-- they can switch it off), and so is the service role (edge functions, cron).
-- The countdown is computed from server time (get_system_status returns it).
--
-- "Logout all" is done by deleting sessions, which makes every device's token
-- refresh fail, plus a version number the apps compare so they sign out at once.

-- ---------------------------------------------------------------------------
-- 1. The state (one row)
-- ---------------------------------------------------------------------------
create table public.system_state (
  id boolean primary key default true check (id),
  status text not null default 'online' check (status in ('online', 'maintenance', 'lockdown')),
  title text not null default 'We''ll be right back',
  message text not null default 'Saba Live is down for scheduled maintenance. We''ll be back shortly.',
  image_url text,
  -- when maintenance begins (null = now) and is expected to end
  starts_at timestamptz,
  ends_at timestamptz,
  -- true: leave maintenance by itself at ends_at. false (default): stay locked until
  -- the Super Admin ends it, however long it takes.
  auto_end boolean not null default false,
  -- lock the app for everyone: maintenance screen, API refused
  lock_app boolean not null default true,
  -- block signing in and signing up (even when lock_app is off)
  block_logins boolean not null default true,
  -- also lock panel staff (the Super Admin is never locked out)
  lock_panel boolean not null default false,
  app_session_version integer not null default 1,
  admin_session_version integer not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);
insert into public.system_state (id) values (true);

alter table public.system_state enable row level security;
-- readable by everyone (it only holds the message and times); written by the RPCs below
create policy "Anyone can read the system state" on public.system_state for select using (true);

alter publication supabase_realtime add table public.system_state;

-- ---------------------------------------------------------------------------
-- 2. What the state means right now
-- ---------------------------------------------------------------------------
create or replace function public.effective_system_status(p public.system_state)
returns text
language sql stable
as $$
  select case
    when p.status = 'lockdown' then 'lockdown'
    when p.status = 'maintenance'
         and p.starts_at is not null and now() < p.starts_at then 'upcoming'
    when p.status = 'maintenance'
         and p.auto_end and p.ends_at is not null and now() >= p.ends_at then 'online'
    when p.status = 'maintenance' then 'maintenance'
    else 'online'
  end;
$$;

-- For the apps and the panel. Callable before sign-in and while locked.
create or replace function public.get_system_status()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'status', public.effective_system_status(s),
    'configured', s.status,
    'title', s.title,
    'message', s.message,
    'image_url', s.image_url,
    'starts_at', s.starts_at,
    'ends_at', s.ends_at,
    'auto_end', s.auto_end,
    'lock_app', s.lock_app,
    'block_logins', s.block_logins,
    'lock_panel', s.lock_panel,
    'app_session_version', s.app_session_version,
    'admin_session_version', s.admin_session_version,
    -- the countdown runs from this, not from the phone's own clock
    'server_time', now()
  )
  from public.system_state s where s.id;
$$;
revoke execute on function public.get_system_status() from public;
grant execute on function public.get_system_status() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The gate: runs before every API request
-- ---------------------------------------------------------------------------
-- Fails OPEN: if anything inside goes wrong the request is let through — a bug
-- here must never be able to take the whole platform down.
create or replace function public.maintenance_gate()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  s public.system_state;
  v_status text;
  v_claims jsonb;
  v_role text;
  v_sub uuid;
  v_path text;
  v_staff public.staff_role;
  v_locked boolean := false;
begin
  begin
    select * into s from public.system_state where id;
    -- the usual case: nothing to do
    if not found or s.status = 'online' then
      return;
    end if;
    v_status := public.effective_system_status(s);
    if v_status not in ('maintenance', 'lockdown') then
      return;
    end if;

    v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
    v_role := coalesce(v_claims ->> 'role', '');
    if v_role = 'service_role' then
      return;
    end if;

    -- the screens must always be able to ask what is going on
    v_path := coalesce(current_setting('request.path', true), '');
    if v_path like '%/rpc/get_system_status' or v_path like '%/rpc/request_context' then
      return;
    end if;

    begin
      v_sub := nullif(v_claims ->> 'sub', '')::uuid;
    exception when others then
      v_sub := null;
    end;
    if v_sub is not null then
      select role into v_staff from public.staff_roles where user_id = v_sub;
    end if;

    if v_staff = 'super_admin' then
      return;
    end if;

    if v_staff is not null then
      v_locked := v_status = 'lockdown' or s.lock_panel;
    else
      v_locked := v_status = 'lockdown' or s.lock_app;
    end if;

    if v_locked then
      raise exception 'MAINTENANCE_MODE' using
        errcode = 'PT503',
        detail = jsonb_build_object(
          'status', v_status,
          'title', s.title,
          'message', s.message,
          'ends_at', s.ends_at,
          'server_time', now()
        )::text,
        hint = 'The system is under maintenance';
    end if;
  exception
    when sqlstate 'PT503' then
      raise;
    when others then
      return;
  end;
end;
$$;
grant execute on function public.maintenance_gate() to anon, authenticated, service_role;

-- A tiny diagnostic: what PostgREST tells the database about a request.
create or replace function public.request_context()
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'path', current_setting('request.path', true),
    'method', current_setting('request.method', true),
    'role', (nullif(current_setting('request.jwt.claims', true), '')::jsonb) ->> 'role'
  );
$$;
grant execute on function public.request_context() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Super Admin controls
-- ---------------------------------------------------------------------------
create or replace function public.assert_super_admin()
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.current_staff_role() is distinct from 'super_admin' then
    raise exception 'Only the Super Admin can do this' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function public.assert_super_admin() from public;

create or replace function public.set_maintenance(
  p_enabled boolean,
  p_title text default null,
  p_message text default null,
  p_image_url text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_auto_end boolean default false,
  p_lock_app boolean default true,
  p_block_logins boolean default true,
  p_lock_panel boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  perform public.assert_super_admin();

  if p_enabled then
    if p_starts_at is not null and p_ends_at is not null and p_ends_at <= p_starts_at then
      raise exception 'The end time must be after the start time';
    end if;
    if p_ends_at is not null and p_ends_at <= now() then
      raise exception 'The end time is already in the past';
    end if;
  end if;

  update public.system_state set
    status = case when p_enabled then 'maintenance' else 'online' end,
    title = coalesce(nullif(trim(p_title), ''), title),
    message = coalesce(nullif(trim(p_message), ''), message),
    image_url = nullif(trim(coalesce(p_image_url, '')), ''),
    starts_at = p_starts_at,
    ends_at = p_ends_at,
    auto_end = coalesce(p_auto_end, false),
    lock_app = coalesce(p_lock_app, true),
    block_logins = coalesce(p_block_logins, true),
    lock_panel = coalesce(p_lock_panel, false),
    updated_at = now(),
    updated_by = auth.uid()
  where id;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (
    auth.uid(),
    case when p_enabled then 'system.maintenance_on' else 'system.maintenance_off' end,
    coalesce(p_ends_at::text, 'no end time'),
    'critical'
  );
  return public.get_system_status();
end;
$$;
revoke execute on function public.set_maintenance(boolean, text, text, text, timestamptz, timestamptz, boolean, boolean, boolean, boolean) from public;
grant execute on function public.set_maintenance(boolean, text, text, text, timestamptz, timestamptz, boolean, boolean, boolean, boolean) to authenticated;

-- Back to normal, keeping the saved message and settings for next time.
create or replace function public.end_maintenance()
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  perform public.assert_super_admin();
  update public.system_state set status = 'online', updated_at = now(), updated_by = auth.uid() where id;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'system.maintenance_off', 'ended', 'critical');
  return public.get_system_status();
end;
$$;
revoke execute on function public.end_maintenance() from public;
grant execute on function public.end_maintenance() to authenticated;

-- Signs out every app user (everyone who isn't panel staff): their sessions are
-- deleted so no device can refresh, and the version moves so every open app signs
-- out at once. Returns how many sessions were ended.
create or replace function public.logout_all_app_users()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_count integer;
begin
  perform public.assert_super_admin();
  delete from auth.sessions
   where user_id not in (select user_id from public.staff_roles);
  get diagnostics v_count = row_count;
  update public.system_state
     set app_session_version = app_session_version + 1, updated_at = now(), updated_by = auth.uid()
   where id;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'system.logout_all_users', v_count || ' sessions', 'critical');
  return v_count;
end;
$$;
revoke execute on function public.logout_all_app_users() from public;
grant execute on function public.logout_all_app_users() to authenticated;

-- Signs out every panel account except the Super Admin session doing this (so they
-- can't lock themselves out while fixing things).
create or replace function public.logout_all_admins()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_count integer;
  v_mine uuid;
begin
  perform public.assert_super_admin();
  begin
    v_mine := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  exception when others then
    v_mine := null;
  end;
  delete from auth.sessions
   where user_id in (select user_id from public.staff_roles)
     and (v_mine is null and user_id <> auth.uid() or v_mine is not null and id <> v_mine);
  get diagnostics v_count = row_count;
  update public.system_state
     set admin_session_version = admin_session_version + 1, updated_at = now(), updated_by = auth.uid()
   where id;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'system.logout_all_admins', v_count || ' sessions', 'critical');
  return v_count;
end;
$$;
revoke execute on function public.logout_all_admins() from public;
grant execute on function public.logout_all_admins() to authenticated;

-- Emergency lockdown: immediately, no timer, nobody but the Super Admin in. App
-- users are signed out and the app is locked; panel staff are locked out too.
create or replace function public.emergency_lockdown(p_message text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  perform public.assert_super_admin();
  update public.system_state set
    status = 'lockdown',
    title = 'Emergency maintenance',
    message = coalesce(nullif(trim(p_message), ''), 'We''ve paused Saba Live while we deal with an urgent issue. Please check back soon.'),
    starts_at = null,
    ends_at = null,
    lock_app = true,
    block_logins = true,
    lock_panel = true,
    updated_at = now(),
    updated_by = auth.uid()
  where id;
  perform public.logout_all_app_users();
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'system.lockdown', 'emergency lockdown', 'critical');
  return public.get_system_status();
end;
$$;
revoke execute on function public.emergency_lockdown(text) from public;
grant execute on function public.emergency_lockdown(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Switch the gate on (PostgREST runs it before every request)
-- ---------------------------------------------------------------------------
do $outer$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    alter role authenticator set pgrst.db_pre_request = 'public.maintenance_gate';
  end if;
end;
$outer$;
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
