-- Staff roles, agencies, and host-specific profile data. Backs both the
-- Flutter consumer app (host_profiles) and the sabaliveadmin panel
-- (agencies, staff_roles, host_applications, kyc_verifications).

create type public.staff_role as enum ('super_admin', 'admin', 'sub_admin', 'agency_manager');

create table public.agencies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  manager_id uuid references public.profiles (id),
  commission_percent numeric(5, 2) not null default 10.00,
  status text not null default 'pending' check (status in ('active', 'inactive', 'pending')),
  country text not null default 'India',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Grants a staff role to a profile. A sub_admin/agency_manager is always scoped
-- to one agency; admin/super_admin are platform-wide and leave agency_id null.
create table public.staff_roles (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  role public.staff_role not null,
  agency_id uuid references public.agencies (id),
  permissions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint agency_role_requires_agency
    check (role not in ('sub_admin', 'agency_manager') or agency_id is not null)
);

-- ---------------------------------------------------------------- RLS helpers
-- security definer + fixed search_path so these can be called from any RLS
-- policy without recursing into staff_roles' own RLS.
create function public.current_staff_role()
returns public.staff_role
language sql stable security definer set search_path = public
as $$
  select role from public.staff_roles where user_id = auth.uid();
$$;

create function public.current_agency_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select agency_id from public.staff_roles where user_id = auth.uid();
$$;

create function public.is_super_admin()
returns boolean language sql stable
as $$ select public.current_staff_role() = 'super_admin'; $$;

create function public.is_admin_or_above()
returns boolean language sql stable
as $$ select public.current_staff_role() in ('super_admin', 'admin'); $$;

create function public.is_staff()
returns boolean language sql stable
as $$ select public.current_staff_role() is not null; $$;

-- True if the caller manages (or is admin/super_admin over) the given agency.
create function public.manages_agency(target_agency_id uuid)
returns boolean language sql stable
as $$
  select public.is_admin_or_above()
    or (public.current_staff_role() in ('agency_manager', 'sub_admin')
        and public.current_agency_id() = target_agency_id);
$$;

alter table public.agencies enable row level security;
alter table public.staff_roles enable row level security;

create policy "Agencies are viewable by staff and their own manager"
  on public.agencies for select
  using (public.is_staff() or manager_id = auth.uid());

create policy "Only admins manage agencies"
  on public.agencies for insert with check (public.is_admin_or_above());
create policy "Only admins update agencies"
  on public.agencies for update using (public.is_admin_or_above());
create policy "Only admins delete agencies"
  on public.agencies for delete using (public.is_admin_or_above());

create policy "Staff can see roles within their scope"
  on public.staff_roles for select
  using (user_id = auth.uid() or public.is_admin_or_above() or agency_id = public.current_agency_id());

create policy "Only super admins assign roles"
  on public.staff_roles for insert with check (public.is_super_admin());
create policy "Only super admins change roles"
  on public.staff_roles for update using (public.is_super_admin());
create policy "Only super admins revoke roles"
  on public.staff_roles for delete using (public.is_super_admin());

-- ---------------------------------------------------------- host extensions
create table public.host_profiles (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  agency_id uuid references public.agencies (id),
  tier text not null default 'bronze' check (tier in ('bronze', 'silver', 'gold', 'platinum')),
  rating numeric(2, 1) not null default 5.0,
  live_hours_total numeric(10, 1) not null default 0,
  kyc_status text not null default 'not_submitted'
    check (kyc_status in ('not_submitted', 'pending', 'verified', 'rejected')),
  status text not null default 'active' check (status in ('active', 'inactive', 'suspended', 'banned')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.host_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references public.profiles (id),
  agency_id uuid references public.agencies (id),
  experience text,
  followers_other_apps integer not null default 0,
  status text not null default 'pending' check (status in ('pending', 'under_review', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.kyc_verifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id),
  document_type text,
  document_url text,
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.host_profiles enable row level security;
alter table public.host_applications enable row level security;
alter table public.kyc_verifications enable row level security;

create policy "Host profiles are publicly viewable"
  on public.host_profiles for select using (true);
create policy "Staff manage host profiles in their scope"
  on public.host_profiles for update using (public.manages_agency(agency_id));
create policy "Staff create host profiles"
  on public.host_profiles for insert with check (public.is_admin_or_above());

create policy "Applicants see their own application"
  on public.host_applications for select
  using (applicant_id = auth.uid() or public.manages_agency(agency_id));
create policy "Anyone signed in can apply to be a host"
  on public.host_applications for insert with check (applicant_id = auth.uid());
create policy "Staff review applications in their scope"
  on public.host_applications for update using (public.manages_agency(agency_id));

create policy "Owners and staff see KYC records"
  on public.kyc_verifications for select
  using (profile_id = auth.uid() or public.is_admin_or_above());
create policy "Owners submit their own KYC"
  on public.kyc_verifications for insert with check (profile_id = auth.uid());
create policy "Admins review KYC"
  on public.kyc_verifications for update using (public.is_admin_or_above());

-- Counters on profiles must only move through triggers (follows, gifts, etc.),
-- never a direct client UPDATE — enforce at the column-privilege level.
revoke update on public.profiles from authenticated;
grant update (name, username, bio, location, avatar_url) on public.profiles to authenticated;
