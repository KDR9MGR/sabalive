-- Going live is now gated behind an agency-issued host code. Agencies (and
-- admins) generate codes with an expiry chosen at generation time; a user
-- redeems one to get a time-limited "host grant". Codes and grants can be
-- banned. `live_streams` INSERT now requires an active grant (staff exempt
-- so they can still test).

-- ─────────────────────────────────────────────── host_codes
create table public.host_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  agency_id uuid references public.agencies (id) on delete set null,
  created_by uuid references public.profiles (id),
  label text,
  max_uses integer not null default 1 check (max_uses between 1 and 500),
  used_count integer not null default 0,
  expires_at timestamptz not null,
  status text not null default 'active' check (status in ('active', 'banned')),
  created_at timestamptz not null default now()
);

create index host_codes_agency_idx on public.host_codes (agency_id, created_at desc);

alter table public.host_codes enable row level security;

create policy "Staff see host codes they manage"
  on public.host_codes for select
  using (public.is_admin_or_above() or public.manages_agency(agency_id));
-- writes go only through the RPCs below (SECURITY DEFINER)

-- ─────────────────────────────────────────────── host_grants
create table public.host_grants (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  code_id uuid references public.host_codes (id) on delete set null,
  agency_id uuid references public.agencies (id) on delete set null,
  granted_by uuid references public.profiles (id),
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  status text not null default 'active'
    check (status in ('active', 'revoked', 'banned')),
  ban_reason text,
  created_at timestamptz not null default now()
);

create index host_grants_profile_idx on public.host_grants (profile_id, status);
create index host_grants_agency_idx on public.host_grants (agency_id, granted_at desc);

alter table public.host_grants enable row level security;

create policy "Owners and managing staff see host grants"
  on public.host_grants for select
  using (
    profile_id = auth.uid()
    or public.is_admin_or_above()
    or public.manages_agency(agency_id)
  );

-- ─────────────────────────────────────────────── helpers
create function public.has_active_host_access(p_uid uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select
    exists (select 1 from public.staff_roles where user_id = p_uid)
    or exists (
      select 1 from public.host_grants
      where profile_id = p_uid and status = 'active'
        and (expires_at is null or expires_at > now())
    );
$$;

grant execute on function public.has_active_host_access(uuid) to authenticated;

create function public.sync_host_flag(p_uid uuid)
returns void language sql security definer set search_path = public
as $$
  update public.profiles set is_host = exists (
    select 1 from public.host_grants
    where profile_id = p_uid and status = 'active'
      and (expires_at is null or expires_at > now())
  )
  where id = p_uid;
$$;

revoke execute on function public.sync_host_flag(uuid) from public;

-- ─────────────────────────────────────────────── RPCs
create function public.generate_host_code(
  p_expires_at timestamptz,
  p_label text default null,
  p_max_uses integer default 1
) returns public.host_codes
language plpgsql security definer set search_path = public
as $$
declare
  v_code text;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_row public.host_codes;
  i integer;
begin
  if not public.is_staff() then
    raise exception 'Only staff can generate host codes';
  end if;
  if p_expires_at is null or p_expires_at <= now() then
    raise exception 'Expiry must be in the future';
  end if;
  if coalesce(p_max_uses, 1) < 1 or coalesce(p_max_uses, 1) > 500 then
    raise exception 'max_uses must be 1..500';
  end if;

  loop
    v_code := '';
    for i in 1..8 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.host_codes where code = v_code);
  end loop;

  insert into public.host_codes (code, agency_id, created_by, label, max_uses, expires_at)
  values (v_code, public.current_agency_id(), auth.uid(),
          nullif(trim(p_label), ''), coalesce(p_max_uses, 1), p_expires_at)
  returning * into v_row;
  return v_row;
end;
$$;

grant execute on function public.generate_host_code(timestamptz, text, integer) to authenticated;

create function public.redeem_host_code(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_code public.host_codes;
  v_existing public.host_grants;
begin
  if v_me is null then
    raise exception 'Sign in first';
  end if;

  -- already have live access? just report it
  select * into v_existing from public.host_grants
  where profile_id = v_me and status = 'active'
    and (expires_at is null or expires_at > now())
  order by expires_at desc nulls first limit 1;
  if v_existing.id is not null then
    return jsonb_build_object('ok', true, 'already', true,
      'expires_at', v_existing.expires_at);
  end if;

  select * into v_code from public.host_codes
  where upper(code) = upper(trim(p_code));
  if v_code.id is null then
    raise exception 'That code is not valid';
  end if;
  if v_code.status = 'banned' then
    raise exception 'That code has been disabled';
  end if;
  if v_code.expires_at <= now() then
    raise exception 'That code has expired';
  end if;
  if v_code.used_count >= v_code.max_uses then
    raise exception 'That code has already been used';
  end if;

  insert into public.host_grants
    (profile_id, code_id, agency_id, granted_by, expires_at)
  values (v_me, v_code.id, v_code.agency_id, v_code.created_by, v_code.expires_at);

  update public.host_codes set used_count = used_count + 1 where id = v_code.id;
  perform public.sync_host_flag(v_me);

  return jsonb_build_object('ok', true, 'already', false,
    'expires_at', v_code.expires_at);
end;
$$;

grant execute on function public.redeem_host_code(text) to authenticated;

create function public.my_host_access()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_grant public.host_grants;
  v_banned boolean;
begin
  if v_me is null then
    return jsonb_build_object('has_access', false);
  end if;
  if exists (select 1 from public.staff_roles where user_id = v_me) then
    return jsonb_build_object('has_access', true, 'staff', true);
  end if;

  select * into v_grant from public.host_grants
  where profile_id = v_me and status = 'active'
    and (expires_at is null or expires_at > now())
  order by expires_at desc nulls first limit 1;

  v_banned := exists (
    select 1 from public.host_grants
    where profile_id = v_me and status = 'banned'
  );

  return jsonb_build_object(
    'has_access', v_grant.id is not null,
    'expires_at', v_grant.expires_at,
    'banned', coalesce(v_banned, false)
  );
end;
$$;

grant execute on function public.my_host_access() to authenticated;

create function public.set_host_code_status(p_code_id uuid, p_status text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_code public.host_codes;
  r record;
begin
  select * into v_code from public.host_codes where id = p_code_id;
  if v_code.id is null then
    raise exception 'Code not found';
  end if;
  if not (public.is_admin_or_above() or public.manages_agency(v_code.agency_id)) then
    raise exception 'Not allowed to manage this code';
  end if;
  if p_status not in ('active', 'banned') then
    raise exception 'status must be active or banned';
  end if;

  update public.host_codes set status = p_status where id = p_code_id;

  if p_status = 'banned' then
    for r in
      update public.host_grants set status = 'banned', ban_reason = 'code disabled'
      where code_id = p_code_id and status = 'active'
      returning profile_id
    loop
      perform public.sync_host_flag(r.profile_id);
    end loop;
  end if;
end;
$$;

grant execute on function public.set_host_code_status(uuid, text) to authenticated;

create function public.set_host_grant_status(
  p_grant_id uuid, p_status text, p_reason text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_grant public.host_grants;
begin
  select * into v_grant from public.host_grants where id = p_grant_id;
  if v_grant.id is null then
    raise exception 'Grant not found';
  end if;
  if not (public.is_admin_or_above() or public.manages_agency(v_grant.agency_id)) then
    raise exception 'Not allowed to manage this grant';
  end if;
  if p_status not in ('active', 'revoked', 'banned') then
    raise exception 'invalid status';
  end if;

  update public.host_grants
    set status = p_status,
        ban_reason = case when p_status = 'active' then null else nullif(trim(p_reason), '') end
  where id = p_grant_id;

  perform public.sync_host_flag(v_grant.profile_id);
end;
$$;

grant execute on function public.set_host_grant_status(uuid, text, text) to authenticated;

-- ─────────────────────────────────────────────── gate live_streams
drop policy if exists "Signed-in users start their own stream" on public.live_streams;

create policy "Approved hosts start their own stream"
  on public.live_streams for insert
  with check (host_id = auth.uid() and public.has_active_host_access(auth.uid()));
