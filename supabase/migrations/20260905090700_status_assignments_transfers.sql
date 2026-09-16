-- Gaps found while cross-checking the schema against both the Flutter app
-- and the sabaliveadmin panel: any profile (not just hosts) can be
-- suspended, sub-admins are assigned specific hosts to manage, and hosts /
-- sub-admins can be requested to transfer between agencies.

alter table public.profiles
  add column status text not null default 'active' check (status in ('active', 'inactive', 'suspended'));

-- status is deliberately NOT in the column grant from the profiles migration
-- (name/username/bio/location/avatar_url only), so no client — including an
-- admin's own session — can UPDATE it directly. Moderation goes through this
-- function instead, consistent with the other admin-gated state changes.
create function public.set_profile_status(p_profile_id uuid, p_status text)
returns public.profiles
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.profiles;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can change a user''s status';
  end if;
  if p_status not in ('active', 'inactive', 'suspended') then
    raise exception 'Invalid status %', p_status;
  end if;

  update public.profiles set status = p_status where id = p_profile_id returning * into v_row;
  return v_row;
end;
$$;

revoke execute on function public.set_profile_status(uuid, text) from anon;

create table public.assignments (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles (id),
  sub_admin_id uuid not null references public.profiles (id),
  shift text not null default 'flexible' check (shift in ('morning', 'evening', 'night', 'flexible')),
  target_hours numeric(6, 1) not null default 0,
  done_hours numeric(6, 1) not null default 0,
  status text not null default 'on_track' check (status in ('on_track', 'behind', 'exceeded')),
  created_at timestamptz not null default now(),
  unique (host_id, sub_admin_id)
);

create index assignments_sub_admin_idx on public.assignments (sub_admin_id);

alter table public.assignments enable row level security;

create policy "Those involved and staff see an assignment"
  on public.assignments for select
  using (
    host_id = auth.uid()
    or sub_admin_id = auth.uid()
    or public.is_admin_or_above()
    or exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = assignments.host_id and public.manages_agency(hp.agency_id)
    )
  );
create policy "Staff create assignments in their scope"
  on public.assignments for insert
  with check (
    public.is_admin_or_above()
    or exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = assignments.host_id and public.manages_agency(hp.agency_id)
    )
  );
create policy "Staff update assignments in their scope"
  on public.assignments for update
  using (
    public.is_admin_or_above()
    or exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = assignments.host_id and public.manages_agency(hp.agency_id)
    )
  );

-- ------------------------------------------------------------ agency transfers
-- Moving a host / sub-admin from one agency to another — distinct from a
-- coin_grants transfer, which moves currency, not a person.
create table public.transfer_requests (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('host', 'sub_admin')),
  subject_id uuid not null references public.profiles (id),
  from_agency_id uuid references public.agencies (id),
  to_agency_id uuid not null references public.agencies (id),
  requested_by uuid not null references public.profiles (id),
  reason text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check (from_agency_id is distinct from to_agency_id)
);

create index transfer_requests_subject_idx on public.transfer_requests (subject_id);
create index transfer_requests_from_agency_idx on public.transfer_requests (from_agency_id);
create index transfer_requests_to_agency_idx on public.transfer_requests (to_agency_id);
create index transfer_requests_requested_by_idx on public.transfer_requests (requested_by);
create index transfer_requests_decided_by_idx on public.transfer_requests (decided_by);

alter table public.transfer_requests enable row level security;

create policy "Staff in scope see transfer requests"
  on public.transfer_requests for select
  using (
    public.is_admin_or_above()
    or public.manages_agency(from_agency_id)
    or public.manages_agency(to_agency_id)
  );
create policy "Agency staff request a transfer"
  on public.transfer_requests for insert
  with check (requested_by = auth.uid() and (public.manages_agency(from_agency_id) or public.is_admin_or_above()));
create policy "Admins decide transfer requests"
  on public.transfer_requests for update using (public.is_admin_or_above());

-- Approving a host transfer actually moves them — kept as an explicit
-- function (rather than a trigger on UPDATE) so the decision and the move
-- are one auditable, atomic action.
create function public.decide_transfer_request(p_request_id uuid, p_approve boolean)
returns public.transfer_requests
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.transfer_requests;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can decide transfer requests';
  end if;

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
$$;

revoke execute on function public.decide_transfer_request(uuid, boolean) from anon;
