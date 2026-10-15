-- Ban hardening: a ban follows the person, not just one phone.
--
-- What a device ban could not do before, and what closes it:
--   * deleting the account wiped the ban (user_bans / banned_devices cascaded with the profile)
--       -> bans now survive the account: user_bans.user_id is set null instead of cascading.
--   * a factory reset changes the Android id, so the banned phone looked new
--       -> register_device_v2 records EVERY id the app sends (the app now also sends a hardware DRM id that survives a
--          reset) and spreads a ban to all of them; check_signup_access checks them all before sign-in.
--   * a new account with the same Google / Apple / email / phone identity (or a dotted / +tagged Gmail variant)
--       -> banned_identities: an ID or device ban puts the user's login identities on a blocklist that outlives the account;
--          a BEFORE INSERT trigger on auth.users / auth.identities refuses to create such an account for ANY client.
--   * quick re-sign-up from the same network
--       -> banned_ips: the IPs the user logged in from in the last 24 h are blocked for NEW sign-ups for 24 h (an IP seen
--          with 4+ different accounts is skipped: it is a shared network). Enforced by check_signup_access for email / phone
--          sign-ups and by the Auth "Before User Created" hook (before_user_created_hook) for every sign-up once that hook is
--          switched on in the dashboard (Authentication -> Hooks), which is also the only place the sign-up IP is visible.
--   * staff could not see who else uses the same phone / IP / identity -> admin_linked_accounts().
-- Everything is additive (new tables, new functions, new triggers on user_bans / auth tables) except user_bans.user_id, which
-- becomes nullable. Existing functions and the apps already installed keep working unchanged.
-- Rollback: supabase/rollbacks/20261015100000_down.sql.

-- ---------------------------------------------------------------------------
-- 1. A ban outlives the account it was placed on
-- ---------------------------------------------------------------------------
alter table public.user_bans alter column user_id drop not null;
alter table public.user_bans drop constraint if exists user_bans_user_id_fkey;
alter table public.user_bans add constraint user_bans_user_id_fkey
  foreign key (user_id) references public.profiles (id) on delete set null;

-- ---------------------------------------------------------------------------
-- 2. Identity blocklist and short IP block
-- ---------------------------------------------------------------------------
create table if not exists public.banned_identities (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('email', 'phone', 'google', 'apple', 'facebook', 'other')),
  value text not null,                 -- normalized (see normalize_identity)
  ban_id uuid,                         -- the ban that created it; no foreign key: it must outlive the account and its bans
  source_user uuid,                    -- the account it came from (no foreign key, same reason)
  ends_at timestamptz,                 -- null = permanent
  lifted_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists banned_identities_once on public.banned_identities (kind, value, ban_id);
create index if not exists banned_identities_lookup on public.banned_identities (kind, value) where lifted_at is null;

create table if not exists public.banned_ips (
  id uuid primary key default gen_random_uuid(),
  ip text not null,
  ban_id uuid,
  ends_at timestamptz not null,
  lifted_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists banned_ips_lookup on public.banned_ips (ip) where lifted_at is null;

alter table public.banned_identities enable row level security;
alter table public.banned_ips enable row level security;
drop policy if exists "Admins see banned identities" on public.banned_identities;
create policy "Admins see banned identities" on public.banned_identities for select using (public.is_admin_or_above());
drop policy if exists "Admins see banned ips" on public.banned_ips;
create policy "Admins see banned ips" on public.banned_ips for select using (public.is_admin_or_above());

-- one canonical spelling per identity, so a dotted / +tagged Gmail or a phone with another prefix still matches
create or replace function public.normalize_identity(p_kind text, p_value text)
returns text
language sql immutable set search_path = public
as $$
  select case
    when p_value is null or btrim(p_value) = '' then null
    when p_kind = 'email' then (
      select case
               when d in ('gmail.com', 'googlemail.com') then replace(split_part(l, '+', 1), '.', '') || '@gmail.com'
               else split_part(l, '+', 1) || '@' || d
             end
        from (select split_part(lower(btrim(p_value)), '@', 1) as l, split_part(lower(btrim(p_value)), '@', 2) as d) x)
    when p_kind = 'phone' then (
      select case when length(dg) >= 10 then right(dg, 10) else nullif(dg, '') end
        from (select regexp_replace(p_value, '[^0-9]', '', 'g') as dg) x)
    else btrim(p_value)
  end;
$$;

create or replace function public.identity_ban_active(p_kind text, p_value text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.normalize_identity(p_kind, p_value) is not null and exists (
    select 1 from public.banned_identities i
     where i.kind = p_kind
       and i.value = public.normalize_identity(p_kind, p_value)
       and i.lifted_at is null
       and (i.ends_at is null or i.ends_at > now())), false);
$$;
revoke execute on function public.identity_ban_active(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Capture the blocklist when an ID / device ban is placed, release it when the ban is lifted
-- ---------------------------------------------------------------------------
create or replace function public.capture_ban_signals()
returns trigger
language plpgsql security definer set search_path = public, auth
as $$
begin
  if new.user_id is null or new.kind not in ('account', 'device') then return new; end if;
  begin
    insert into public.banned_identities (kind, value, ban_id, source_user, ends_at)
    select s.k, s.v, new.id, new.user_id, new.ends_at
      from (
        select 'email'::text as k, public.normalize_identity('email', u.email) as v from auth.users u where u.id = new.user_id
        union
        select 'phone', public.normalize_identity('phone', u.phone) from auth.users u where u.id = new.user_id
        union
        select 'email', public.normalize_identity('email', i.identity_data ->> 'email') from auth.identities i where i.user_id = new.user_id
        union
        select case when i.provider in ('google', 'apple', 'facebook') then i.provider else 'other' end,
               public.normalize_identity('other', i.provider_id)
          from auth.identities i where i.user_id = new.user_id and i.provider not in ('email', 'phone')
      ) s
     where s.v is not null
    on conflict do nothing;

    insert into public.banned_ips (ip, ban_id, ends_at)
    select distinct e.ip, new.id,
           case when new.ends_at is null or new.ends_at > new.created_at + interval '24 hours'
                then new.created_at + interval '24 hours' else new.ends_at end
      from public.user_login_events e
     where e.user_id = new.user_id and e.ip is not null and e.created_at > new.created_at - interval '24 hours'
       -- an IP that 4+ different accounts have used is a shared network, not one person: never block it
       and (select count(distinct x.user_id) from public.user_login_events x
             where x.ip = e.ip and x.created_at > now() - interval '30 days') < 4;
  exception when others then
    null; -- placing a ban must never fail because of this
  end;
  return new;
end;
$$;
drop trigger if exists user_bans_capture_signals on public.user_bans;
create trigger user_bans_capture_signals after insert on public.user_bans
  for each row execute function public.capture_ban_signals();

create or replace function public.release_ban_signals()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update public.banned_identities set lifted_at = new.lifted_at where ban_id = new.id and lifted_at is null;
  update public.banned_ips set lifted_at = new.lifted_at where ban_id = new.id and lifted_at is null;
  return new;
end;
$$;
drop trigger if exists user_bans_release_signals on public.user_bans;
create trigger user_bans_release_signals after update of lifted_at on public.user_bans
  for each row when (new.lifted_at is not null and old.lifted_at is null)
  execute function public.release_ban_signals();

-- bans already in force get their identities on the blocklist too (no IPs: those are a 24 hour matter)
insert into public.banned_identities (kind, value, ban_id, source_user, ends_at)
select s.k, s.v, b.id, b.user_id, b.ends_at
  from public.user_bans b
  cross join lateral (
    select 'email'::text as k, public.normalize_identity('email', u.email) as v from auth.users u where u.id = b.user_id
    union
    select 'phone', public.normalize_identity('phone', u.phone) from auth.users u where u.id = b.user_id
    union
    select 'email', public.normalize_identity('email', i.identity_data ->> 'email') from auth.identities i where i.user_id = b.user_id
    union
    select case when i.provider in ('google', 'apple', 'facebook') then i.provider else 'other' end,
           public.normalize_identity('other', i.provider_id)
      from auth.identities i where i.user_id = b.user_id and i.provider not in ('email', 'phone')
  ) s
 where b.kind in ('account', 'device') and b.lifted_at is null and (b.ends_at is null or b.ends_at > now())
   and b.user_id is not null and s.v is not null
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 4. Server-side refusal to create an account with a banned identity (any client, old or modified)
-- ---------------------------------------------------------------------------
create or replace function public.block_banned_identity_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_blocked boolean := false;
begin
  begin
    v_blocked := public.identity_ban_active('email', new.email) or public.identity_ban_active('phone', new.phone);
  exception when others then
    v_blocked := false; -- fail open: a bug here must never stop honest sign-ups
  end;
  if v_blocked then
    raise exception 'This account cannot be created' using errcode = 'BN010';
  end if;
  return new;
end;
$$;
drop trigger if exists block_banned_identity_user on auth.users;
create trigger block_banned_identity_user before insert on auth.users
  for each row execute function public.block_banned_identity_user();

create or replace function public.block_banned_identity_link()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_blocked boolean := false;
begin
  begin
    if new.provider in ('google', 'apple', 'facebook') then
      v_blocked := public.identity_ban_active(new.provider, new.provider_id);
    end if;
    v_blocked := v_blocked or public.identity_ban_active('email', new.identity_data ->> 'email');
  exception when others then
    v_blocked := false;
  end;
  if v_blocked then
    raise exception 'This account cannot be created' using errcode = 'BN010';
  end if;
  return new;
end;
$$;
drop trigger if exists block_banned_identity_link on auth.identities;
create trigger block_banned_identity_link before insert on auth.identities
  for each row execute function public.block_banned_identity_link();

-- ---------------------------------------------------------------------------
-- 5. Before any sign-in / sign-up: devices (every id), identity, and for a NEW account the IP
-- ---------------------------------------------------------------------------
create or replace function public.device_ban_info(p_ids text[])
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object('banned', true, 'reason', 'device', 'until', max(b.ends_at), 'permanent', bool_or(b.ends_at is null))
       from public.banned_devices bd
       join public.user_bans b on b.id = bd.ban_id
      where bd.device_id = any (coalesce(p_ids, '{}')) and public.ban_active(b)
     having count(*) > 0),
    jsonb_build_object('banned', false));
$$;
revoke execute on function public.device_ban_info(text[]) from public, anon, authenticated;

create or replace function public.check_signup_access(
  p_device_ids text[] default '{}', p_email text default null, p_phone text default null, p_new_account boolean default false
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_res jsonb;
  v_ip text;
  v_until timestamptz;
begin
  v_res := public.device_ban_info(p_device_ids);
  if (v_res ->> 'banned')::boolean then return v_res; end if;

  if public.identity_ban_active('email', p_email) or public.identity_ban_active('phone', p_phone) then
    return jsonb_build_object('banned', true, 'reason', 'identity', 'permanent', true);
  end if;

  -- the short IP block applies to creating a NEW account only, never to signing in to an existing one
  if p_new_account then
    v_ip := nullif(btrim(split_part(
      coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1)), '');
    if v_ip is not null then
      select max(i.ends_at) into v_until from public.banned_ips i
       where i.ip = v_ip and i.lifted_at is null and i.ends_at > now();
      if v_until is not null then
        return jsonb_build_object('banned', true, 'reason', 'ip', 'until', v_until, 'permanent', false);
      end if;
    end if;
  end if;
  return jsonb_build_object('banned', false);
end;
$$;
revoke execute on function public.check_signup_access(text[], text, text, boolean) from public;
grant execute on function public.check_signup_access(text[], text, text, boolean) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. register_device_v2: every id the app knows (Android id + hardware DRM id), a ban spreads to all of them
-- ---------------------------------------------------------------------------
create or replace function public.register_device_v2(
  p_device_id text, p_platform text default null, p_model text default null, p_extra_ids text[] default '{}'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_ids text[];
  v_id text;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in';
  end if;
  v_ids := array(
    select distinct btrim(x) from unnest(array[p_device_id] || coalesce(p_extra_ids, '{}')) x
     where coalesce(btrim(x), '') <> '');
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('banned', false);
  end if;

  foreach v_id in array v_ids loop
    insert into public.user_devices (user_id, device_id, platform, model)
    values (auth.uid(), v_id, p_platform, p_model)
    on conflict (user_id, device_id) do update
      set last_seen_at = now(),
          platform = coalesce(excluded.platform, public.user_devices.platform),
          model = coalesce(excluded.model, public.user_devices.model);
  end loop;

  -- a ban on this account binds to every id it presents (register_device did this for one id)
  insert into public.banned_devices (device_id, ban_id)
  select i, b.id
    from public.user_bans b, unnest(v_ids) i
   where b.user_id = auth.uid() and b.kind in ('account', 'device') and public.ban_active(b)
  on conflict do nothing;

  -- a ban on ANY of these ids spreads to all of them: a factory reset changes the Android id but not the DRM id
  insert into public.banned_devices (device_id, ban_id)
  select i, bd.ban_id
    from public.banned_devices bd
    join public.user_bans b on b.id = bd.ban_id
    cross join unnest(v_ids) i
   where bd.device_id = any (v_ids) and b.kind in ('account', 'device') and public.ban_active(b)
  on conflict do nothing;

  return public.device_ban_info(v_ids);
end;
$$;
revoke execute on function public.register_device_v2(text, text, text, text[]) from public;
grant execute on function public.register_device_v2(text, text, text, text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Staff: who else uses the same phone, network or login identity
-- ---------------------------------------------------------------------------
create or replace function public.admin_linked_accounts(p_user uuid)
returns table (
  user_id uuid, name text, username text, display_id bigint, status text,
  link text, detail text, banned boolean, last_seen timestamptz
)
language plpgsql stable security definer set search_path = public, auth
as $$
begin
  if not public.staff_cap_on('view_user_profile') then
    raise exception 'Not allowed to see linked accounts';
  end if;

  return query
  with me as (select u.email, u.phone from auth.users u where u.id = p_user),
  by_device as (
    select d2.user_id as uid, 'device'::text as lnk, d2.device_id as dtl, d2.last_seen_at as seen
      from public.user_devices d1
      join public.user_devices d2 on d2.device_id = d1.device_id and d2.user_id <> d1.user_id
     where d1.user_id = p_user
  ), by_ip as (
    select e2.user_id as uid, 'ip'::text as lnk, e2.ip as dtl, max(e2.created_at) as seen
      from public.user_login_events e1
      join public.user_login_events e2 on e2.ip = e1.ip and e2.user_id <> e1.user_id
     where e1.user_id = p_user and e1.ip is not null
       and e1.created_at > now() - interval '30 days' and e2.created_at > now() - interval '30 days'
     group by e2.user_id, e2.ip
  ), by_identity as (
    select u.id as uid, 'identity'::text as lnk,
           case when me.email is not null and public.normalize_identity('email', u.email) = public.normalize_identity('email', me.email)
                then 'same email' else 'same phone' end as dtl,
           u.created_at as seen
      from auth.users u, me
     where u.id <> p_user
       and ((me.email is not null and public.normalize_identity('email', u.email) = public.normalize_identity('email', me.email))
         or (me.phone is not null and public.normalize_identity('phone', u.phone) = public.normalize_identity('phone', me.phone)))
  ), hits as (
    select * from by_device union all select * from by_ip union all select * from by_identity
  )
  select h.uid, p.name, p.username, p.display_id, p.status, h.lnk, h.dtl,
         exists (select 1 from public.user_bans b
                  where b.user_id = h.uid and b.kind in ('account', 'device') and public.ban_active(b)),
         h.seen
    from hits h
    join public.profiles p on p.id = h.uid
   where not p.is_ghost
   order by case h.lnk when 'identity' then 0 when 'device' then 1 else 2 end, h.seen desc
   limit 100;
end;
$$;
revoke execute on function public.admin_linked_accounts(uuid) from public, anon;
grant execute on function public.admin_linked_accounts(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. The Auth "Before User Created" hook: the one place a sign-up's IP is visible, for every client.
--    Inert until it is switched on (dashboard: Authentication -> Hooks -> Before User Created -> Postgres function
--    public.before_user_created_hook). It fails open.
-- ---------------------------------------------------------------------------
create or replace function public.before_user_created_hook(event jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_ip text := nullif(btrim(event -> 'metadata' ->> 'ip_address'), '');
  v_email text := event -> 'user' ->> 'email';
  v_phone text := event -> 'user' ->> 'phone';
  v_provider text := event -> 'user' -> 'app_metadata' ->> 'provider';
  v_sub text := coalesce(event -> 'user' -> 'user_metadata' ->> 'provider_id', event -> 'user' -> 'user_metadata' ->> 'sub');
  v_blocked boolean := false;
begin
  begin
    v_blocked := public.identity_ban_active('email', v_email)
      or public.identity_ban_active('phone', v_phone)
      or (v_provider in ('google', 'apple', 'facebook') and v_sub is not null and public.identity_ban_active(v_provider, v_sub));
    if not v_blocked and v_ip is not null then
      v_blocked := exists (select 1 from public.banned_ips i where i.ip = v_ip and i.lifted_at is null and i.ends_at > now());
    end if;
  exception when others then
    v_blocked := false;
  end;
  if v_blocked then
    return jsonb_build_object('error', jsonb_build_object('message', 'This account cannot be created right now.', 'http_code', 403));
  end if;
  return '{}'::jsonb;
end;
$$;
revoke execute on function public.before_user_created_hook(jsonb) from public, anon, authenticated;
do $hook$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant usage on schema public to supabase_auth_admin;
    grant execute on function public.before_user_created_hook(jsonb) to supabase_auth_admin;
  end if;
end;
$hook$;

-- ---------------------------------------------------------------------------
-- 9. Supabase hands EXECUTE to anon / authenticated on every new function; take it away where it is not wanted
-- ---------------------------------------------------------------------------
revoke execute on function public.register_device_v2(text, text, text, text[]) from anon;
revoke execute on function public.normalize_identity(text, text) from public, anon, authenticated;
revoke execute on function public.capture_ban_signals() from public, anon, authenticated;
revoke execute on function public.release_ban_signals() from public, anon, authenticated;
revoke execute on function public.block_banned_identity_user() from public, anon, authenticated;
revoke execute on function public.block_banned_identity_link() from public, anon, authenticated;
