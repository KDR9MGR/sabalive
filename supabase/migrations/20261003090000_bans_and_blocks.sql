-- Real suspensions: Live / ID / Device bans (7 days, 30 days or permanent), and
-- enforcement of user-to-user Block.
--
-- Until now "suspended" was only a label: profiles.status = 'suspended' was
-- written by set_profile_status and read by nothing, so a suspended user could
-- still sign in, join lives (join_live_stream, the Agora token and every chat /
-- seat / gift insert were status-blind) and keep an open session. Blocks were
-- stored in `blocks` but enforced nowhere.
--
--   live ban     can't watch, host, chat, gift or take seats; the rest works
--   ID ban       the account can't sign in (auth.users.banned_until), sessions
--                are deleted, and every device it used is banned too
--   device ban   the phone(s) the user has used are blocked for any account
--
-- The server is the authority: BEFORE INSERT triggers cover both RPCs and direct
-- table inserts, and the agora-token function asks live_access_denied_reason.
-- A device is identified by the app's `x-device-id` request header (readable in
-- SQL through request.headers). Denials raise custom SQLSTATEs the app can
-- recognise: BN001 banned, BN002 removed by the host / blocked, BN003 blocked
-- from messaging.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.user_bans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('live', 'account', 'device')),
  starts_at timestamptz not null default now(),
  -- null = permanent
  ends_at timestamptz,
  reason text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  lifted_at timestamptz,
  lifted_by uuid references public.profiles (id) on delete set null,
  lift_note text
);
create index user_bans_user_idx on public.user_bans (user_id);
create index user_bans_active_idx on public.user_bans (kind, ends_at) where lifted_at is null;

-- Devices each user has opened the app on (filled by register_device).
create table public.user_devices (
  user_id uuid not null references public.profiles (id) on delete cascade,
  device_id text not null,
  platform text,
  model text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
create index user_devices_device_idx on public.user_devices (device_id);

-- Device ids covered by an ID ban or a device ban.
create table public.banned_devices (
  device_id text not null,
  ban_id uuid not null references public.user_bans (id) on delete cascade,
  primary key (device_id, ban_id)
);

-- A host removing a viewer from their live ("Block viewer").
create table public.live_stream_viewer_bans (
  live_stream_id uuid not null references public.live_streams (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  banned_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (live_stream_id, user_id)
);

alter table public.user_bans enable row level security;
alter table public.user_devices enable row level security;
alter table public.banned_devices enable row level security;
alter table public.live_stream_viewer_bans enable row level security;

-- Clients never write these; the security-definer functions below do.
create policy "Users see their own bans, admins see all"
  on public.user_bans for select
  using (user_id = auth.uid() or public.is_admin_or_above());
create policy "Admins see devices"
  on public.user_devices for select using (public.is_admin_or_above());
create policy "Admins see banned devices"
  on public.banned_devices for select using (public.is_admin_or_above());
create policy "Viewers, hosts and admins see viewer bans"
  on public.live_stream_viewer_bans for select
  using (
    user_id = auth.uid()
    or public.is_admin_or_above()
    or exists (
      select 1 from public.live_streams s
      where s.id = live_stream_viewer_bans.live_stream_id and s.host_id = auth.uid()
    )
  );

-- The app learns about a ban the moment it is placed.
alter publication supabase_realtime add table public.user_bans;
alter publication supabase_realtime add table public.live_stream_viewer_bans;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
create or replace function public.current_device_id()
returns text
language sql stable
as $$
  select nullif(
    coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-device-id', ''),
    ''
  );
$$;

create or replace function public.ban_active(b public.user_bans)
returns boolean
language sql stable
as $$
  select b.lifted_at is null and (b.ends_at is null or b.ends_at > now());
$$;

create or replace function public.ban_message(p_subject text, p_until timestamptz)
returns text
language sql immutable
as $$
  select case
    when p_until is null or p_until = 'infinity' then p_subject || ' permanently.'
    else p_subject || ' until ' || to_char(p_until at time zone 'UTC', 'DD Mon YYYY') || '.'
  end;
$$;

-- Why (if at all) a user may not use live right now. No row = allowed.
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
revoke execute on function public.live_access_denied_reason(uuid, uuid) from public;
grant execute on function public.live_access_denied_reason(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Enforcement triggers (RPCs and direct inserts alike)
-- ---------------------------------------------------------------------------
create or replace function public.assert_live_allowed()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid;
  v_stream uuid;
  r record;
begin
  -- server-side writers (cron, service role) have no signed-in user
  if auth.uid() is null then
    return new;
  end if;

  if tg_table_name = 'live_stream_viewers' then
    v_user := new.viewer_id; v_stream := new.live_stream_id;
  elsif tg_table_name = 'live_chat_messages' then
    v_user := new.sender_id; v_stream := new.live_stream_id;
  elsif tg_table_name = 'live_stream_seats' then
    v_user := new.occupant_id; v_stream := new.live_stream_id;
  elsif tg_table_name = 'live_streams' then
    v_user := new.host_id; v_stream := null;
  elsif tg_table_name = 'gift_transactions' then
    -- a gift in a DM isn't a live action
    if new.live_stream_id is null then
      return new;
    end if;
    v_user := new.sender_id; v_stream := new.live_stream_id;
  else
    return new;
  end if;

  select * into r from public.live_access_denied_reason(v_user, v_stream);
  if r.code is not null then
    raise exception '%', r.message using errcode = r.code;
  end if;
  return new;
end;
$$;
revoke execute on function public.assert_live_allowed() from public;

create trigger live_stream_viewers_ban_check
  before insert on public.live_stream_viewers
  for each row execute function public.assert_live_allowed();
create trigger live_chat_ban_check
  before insert on public.live_chat_messages
  for each row execute function public.assert_live_allowed();
create trigger live_stream_seats_ban_check
  before insert on public.live_stream_seats
  for each row execute function public.assert_live_allowed();
create trigger live_streams_ban_check
  before insert on public.live_streams
  for each row execute function public.assert_live_allowed();
create trigger gift_transactions_ban_check
  before insert on public.gift_transactions
  for each row execute function public.assert_live_allowed();

-- ---------------------------------------------------------------------------
-- 4. Applying an ID ban to the auth system
-- ---------------------------------------------------------------------------
-- Recomputes the account's auth state from its active ID bans: banned_until
-- (stops sign-in and token refresh), the 'suspended' profile status the panel
-- lists, and signing out every existing session.
create or replace function public.sync_account_ban(p_user uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_active boolean;
  v_until timestamptz;
begin
  select count(*) > 0, max(coalesce(b.ends_at, now() + interval '100 years'))
    into v_active, v_until
    from public.user_bans b
   where b.user_id = p_user and b.kind = 'account' and public.ban_active(b);

  if v_active then
    update auth.users set banned_until = v_until where id = p_user;
    update public.profiles set status = 'suspended' where id = p_user;
    delete from auth.sessions where user_id = p_user;
  else
    update auth.users set banned_until = null where id = p_user and banned_until is not null;
    update public.profiles set status = 'active' where id = p_user and status = 'suspended';
  end if;
end;
$$;
revoke execute on function public.sync_account_ban(uuid) from public;

-- ---------------------------------------------------------------------------
-- 5. Panel RPCs
-- ---------------------------------------------------------------------------
create or replace function public.ban_user(
  p_user uuid, p_kinds text[], p_duration text, p_reason text default null
)
returns setof public.user_bans
language plpgsql security definer set search_path = public
as $$
declare
  v_kind text;
  v_kinds text[];
  v_ends timestamptz;
  v_ban public.user_bans;
begin
  if not public.is_admin_or_above() then
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
  if p_duration not in ('7d', '30d', 'permanent') then
    raise exception 'Duration must be 7d, 30d or permanent';
  end if;
  select array_agg(distinct k) into v_kinds from unnest(p_kinds) k;
  if v_kinds is null or not (v_kinds <@ array['live', 'account', 'device']) then
    raise exception 'Choose at least one of: live, account, device';
  end if;

  v_ends := case p_duration
    when '7d' then now() + interval '7 days'
    when '30d' then now() + interval '30 days'
    else null
  end;

  foreach v_kind in array v_kinds loop
    update public.user_bans
       set lifted_at = now(), lifted_by = auth.uid(), lift_note = 'Replaced by a new ban'
     where user_id = p_user and kind = v_kind and public.ban_active(user_bans);

    insert into public.user_bans (user_id, kind, ends_at, reason, created_by)
    values (p_user, v_kind, v_ends, nullif(trim(p_reason), ''), auth.uid())
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
  values (
    auth.uid(), 'user.banned',
    p_user::text || ' -> ' || array_to_string(v_kinds, '+') || ' for ' || p_duration,
    'warning'
  );
end;
$$;
revoke execute on function public.ban_user(uuid, text[], text, text) from public;
grant execute on function public.ban_user(uuid, text[], text, text) to authenticated;

create or replace function public.lift_ban(p_ban_id uuid, p_note text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_ban public.user_bans;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can lift bans';
  end if;
  perform public.require_capability('manage_users');

  update public.user_bans
     set lifted_at = now(), lifted_by = auth.uid(), lift_note = nullif(trim(p_note), '')
   where id = p_ban_id and lifted_at is null
   returning * into v_ban;
  if not found then
    raise exception 'That ban was not found or is already lifted';
  end if;

  if v_ban.kind = 'account' then
    perform public.sync_account_ban(v_ban.user_id);
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'user.ban_lifted', v_ban.user_id::text || ' -> ' || v_ban.kind, 'info');
end;
$$;
revoke execute on function public.lift_ban(uuid, text) from public;
grant execute on function public.lift_ban(uuid, text) to authenticated;

-- Lifts every active ban of a user (or only the given kinds). Returns how many.
create or replace function public.lift_user_bans(
  p_user uuid, p_note text default null, p_kinds text[] default null
)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_count integer;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can lift bans';
  end if;
  perform public.require_capability('manage_users');

  update public.user_bans
     set lifted_at = now(), lifted_by = auth.uid(), lift_note = nullif(trim(p_note), '')
   where user_id = p_user
     and public.ban_active(user_bans)
     and (p_kinds is null or kind = any (p_kinds));
  get diagnostics v_count = row_count;

  perform public.sync_account_ban(p_user);

  if v_count > 0 then
    insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'user.ban_lifted', p_user::text || ' -> all (' || v_count || ')', 'info');
  end if;
  return v_count;
end;
$$;
revoke execute on function public.lift_user_bans(uuid, text, text[]) from public;
grant execute on function public.lift_user_bans(uuid, text, text[]) to authenticated;

-- The panel's old Suspend / Reactivate buttons keep working — and now enforce.
create or replace function public.set_profile_status(p_profile_id uuid, p_status text)
returns public.profiles
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.profiles;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can change a user''s status';
  end if;
  perform public.require_capability('manage_users');
  if p_status not in ('active', 'inactive', 'suspended') then
    raise exception 'Invalid status %', p_status;
  end if;

  if p_status = 'suspended' then
    perform public.ban_user(p_profile_id, array['account'], 'permanent', 'Suspended from the admin panel');
  elsif p_status = 'active' then
    perform public.lift_user_bans(p_profile_id, 'Reactivated from the admin panel');
  else
    -- inactive is not a ban, but it does end an ID ban
    perform public.lift_user_bans(p_profile_id, 'Set inactive from the admin panel', array['account']);
    update public.profiles set status = 'inactive' where id = p_profile_id;
  end if;

  select * into v_row from public.profiles where id = p_profile_id;
  return v_row;
end;
$$;

-- Flips profiles.status back once an ID ban has run out (banned_until expires on
-- its own, and every check also tests ends_at, so this only tidies the label).
create or replace function public.lift_expired_bans()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r record;
begin
  for r in
    select distinct b.user_id
      from public.user_bans b
      join public.profiles p on p.id = b.user_id and p.status = 'suspended'
     where b.kind = 'account'
       and b.lifted_at is null
       and b.ends_at is not null
       and b.ends_at <= now()
       and not exists (
         select 1 from public.user_bans a
         where a.user_id = b.user_id and a.kind = 'account' and public.ban_active(a)
       )
  loop
    perform public.sync_account_ban(r.user_id);
  end loop;
end;
$$;
revoke execute on function public.lift_expired_bans() from public;

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'lift-expired-bans') then
    perform cron.schedule('lift-expired-bans', '*/5 * * * *', $sql$select public.lift_expired_bans()$sql$);
  end if;
end;
$outer$;

-- ---------------------------------------------------------------------------
-- 6. App RPCs
-- ---------------------------------------------------------------------------
-- {"account": {...}|null, "live": {...}|null, "device": {...}|null}; each has
-- {"until": timestamp|null, "permanent": bool}.
create or replace function public.my_restrictions()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'account', (
      select jsonb_build_object('until', max(b.ends_at), 'permanent', bool_or(b.ends_at is null))
        from public.user_bans b
       where b.user_id = auth.uid() and b.kind = 'account' and public.ban_active(b)
      having count(*) > 0
    ),
    'live', (
      select jsonb_build_object('until', max(b.ends_at), 'permanent', bool_or(b.ends_at is null))
        from public.user_bans b
       where b.user_id = auth.uid() and b.kind = 'live' and public.ban_active(b)
      having count(*) > 0
    ),
    'device', (
      select jsonb_build_object('until', max(b.ends_at), 'permanent', bool_or(b.ends_at is null))
        from public.banned_devices bd
        join public.user_bans b on b.id = bd.ban_id
       where bd.device_id = public.current_device_id() and public.ban_active(b)
      having count(*) > 0
    )
  );
$$;
revoke execute on function public.my_restrictions() from public;
grant execute on function public.my_restrictions() to authenticated;

-- Callable before sign-in so a banned phone can't even start a login.
create or replace function public.check_device_access(p_device_id text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (
      select jsonb_build_object('banned', true, 'until', max(b.ends_at), 'permanent', bool_or(b.ends_at is null))
        from public.banned_devices bd
        join public.user_bans b on b.id = bd.ban_id
       where bd.device_id = p_device_id and public.ban_active(b)
      having count(*) > 0
    ),
    jsonb_build_object('banned', false)
  );
$$;
revoke execute on function public.check_device_access(text) from public;
grant execute on function public.check_device_access(text) to anon, authenticated;

-- Remembers which devices a user opens the app on, and says whether this one is
-- banned. A ban placed before any device was on file binds to the first device
-- the user then registers.
create or replace function public.register_device(
  p_device_id text, p_platform text default null, p_model text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Must be signed in';
  end if;
  if coalesce(trim(p_device_id), '') = '' then
    return jsonb_build_object('banned', false);
  end if;

  insert into public.user_devices (user_id, device_id, platform, model)
  values (auth.uid(), p_device_id, p_platform, p_model)
  on conflict (user_id, device_id) do update
    set last_seen_at = now(),
        platform = coalesce(excluded.platform, public.user_devices.platform),
        model = coalesce(excluded.model, public.user_devices.model);

  insert into public.banned_devices (device_id, ban_id)
  select p_device_id, b.id
    from public.user_bans b
   where b.user_id = auth.uid()
     and b.kind in ('account', 'device')
     and public.ban_active(b)
     and not exists (select 1 from public.banned_devices bd where bd.ban_id = b.id)
  on conflict do nothing;

  return public.check_device_access(p_device_id);
end;
$$;
revoke execute on function public.register_device(text, text, text) from public;
grant execute on function public.register_device(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Block: host removes a viewer; blocked users can't message the blocker
-- ---------------------------------------------------------------------------
create or replace function public.block_viewer(p_stream_id uuid, p_user_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.live_streams where id = p_stream_id and host_id = auth.uid()
  ) then
    raise exception 'Only the host can do this';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'You can''t remove yourself';
  end if;

  insert into public.live_stream_viewer_bans (live_stream_id, user_id, banned_by)
  values (p_stream_id, p_user_id, auth.uid())
  on conflict (live_stream_id, user_id) do nothing;

  update public.live_stream_viewers set left_at = now()
   where live_stream_id = p_stream_id and viewer_id = p_user_id and left_at is null;
  delete from public.live_stream_seats
   where live_stream_id = p_stream_id and occupant_id = p_user_id;
end;
$$;
revoke execute on function public.block_viewer(uuid, uuid) from public;
grant execute on function public.block_viewer(uuid, uuid) to authenticated;

create or replace function public.start_conversation(p_other_id uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_conv uuid;
begin
  if v_me is null then
    raise exception 'not authenticated';
  end if;
  if p_other_id is null or p_other_id = v_me then
    raise exception 'invalid recipient';
  end if;
  if not exists (select 1 from public.profiles where id = p_other_id) then
    raise exception 'recipient not found';
  end if;
  if exists (select 1 from public.blocks where blocker_id = p_other_id and blocked_id = v_me) then
    raise exception 'You can''t message this user.' using errcode = 'BN003';
  end if;

  select c.id into v_conv
  from public.conversations c
  where c.is_group = false
    and exists (
      select 1 from public.conversation_participants p
      where p.conversation_id = c.id and p.profile_id = v_me
    )
    and exists (
      select 1 from public.conversation_participants p
      where p.conversation_id = c.id and p.profile_id = p_other_id
    )
  limit 1;

  if v_conv is not null then
    return v_conv;
  end if;

  insert into public.conversations (is_group, created_by)
  values (false, v_me)
  returning id into v_conv;

  insert into public.conversation_participants (conversation_id, profile_id, role, status)
  values
    (v_conv, v_me, 'member', 'accepted'),
    (v_conv, p_other_id, 'member', 'pending');

  return v_conv;
end;
$$;

-- An existing thread stops accepting messages from someone the other side blocked.
create or replace function public.assert_dm_not_blocked()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    return new;
  end if;
  if exists (
    select 1
      from public.conversation_participants cp
      join public.conversations c on c.id = cp.conversation_id
      join public.blocks bl on bl.blocker_id = cp.profile_id and bl.blocked_id = new.sender_id
     where cp.conversation_id = new.conversation_id
       and not c.is_group
       and cp.profile_id <> new.sender_id
  ) then
    raise exception 'You can''t message this user.' using errcode = 'BN003';
  end if;
  return new;
end;
$$;
revoke execute on function public.assert_dm_not_blocked() from public;

create trigger dm_block_check
  before insert on public.dm_messages
  for each row execute function public.assert_dm_not_blocked();

-- ---------------------------------------------------------------------------
-- 8. Backfill: users already suspended from the panel become real ID bans
-- ---------------------------------------------------------------------------
insert into public.user_bans (user_id, kind, ends_at, reason)
select p.id, 'account', null, 'Suspended before ban types existed'
  from public.profiles p
 where p.status = 'suspended'
   and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
   and not exists (select 1 from public.user_bans b where b.user_id = p.id and b.kind = 'account');

select public.sync_account_ban(u.user_id)
  from (select distinct user_id from public.user_bans where kind = 'account') u;
