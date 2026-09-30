-- Replaces the instant self-service "host code" gate with an agency-
-- approval flow: a user types the agency's public display_id (not a code),
-- which files a pending live_requests row (type='go_live_approval') that
-- only that agency (or admins) can see and accept/reject — no host access
-- until approved. host_codes/host_grants/generate_host_code/
-- redeem_host_code (20260909090000) are UNTOUCHED and keep working
-- for their existing admin-panel screens; this flow only stops the APP
-- from calling redeem_host_code for its go-live gate. On approval this
-- still lands in host_grants the same shape a redeemed code would, so
-- has_active_host_access()/live_streams' RLS gate need zero changes.

alter table public.live_requests add column agency_id uuid references public.agencies (id);

create function public.request_go_live(p_agency_display_id bigint)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_agency public.agencies;
begin
  if v_me is null then
    raise exception 'Sign in first';
  end if;

  select * into v_agency from public.agencies where display_id = p_agency_display_id;
  if v_agency.id is null then
    raise exception 'No agency found with that ID';
  end if;

  if exists (
    select 1 from public.live_requests
    where host_id = v_me and agency_id = v_agency.id
      and type = 'go_live_approval' and status = 'pending'
  ) then
    raise exception 'You already have a pending request with this agency';
  end if;

  insert into public.live_requests (host_id, agency_id, type, priority, status)
  values (v_me, v_agency.id, 'go_live_approval', 'medium', 'pending');

  return jsonb_build_object('agency_name', v_agency.name);
end;
$$;

grant execute on function public.request_go_live(bigint) to authenticated;

create function public.decide_live_request(p_id uuid, p_approve boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_request public.live_requests;
  v_allowed boolean;
begin
  select * into v_request from public.live_requests where id = p_id;
  if v_request.id is null then
    raise exception 'Request not found';
  end if;

  -- agency_id first (every new request has it); host_profiles-derived
  -- fallback for rows that predate this migration and never got one.
  v_allowed := public.is_admin_or_above()
    or (v_request.agency_id is not null and public.manages_agency(v_request.agency_id))
    or exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = v_request.host_id and public.manages_agency(hp.agency_id)
    );
  if not v_allowed then
    raise exception 'Not allowed to review this request';
  end if;

  update public.live_requests
    set status = case when p_approve then 'approved' else 'rejected' end,
        reviewed_by = auth.uid(),
        reviewed_at = now()
  where id = p_id;

  if p_approve and v_request.type = 'go_live_approval' and v_request.agency_id is not null then
    -- Only create host_profiles if this host doesn't already belong to an
    -- agency — approving a go-live request isn't meant to silently
    -- reassign an existing host to a different agency.
    insert into public.host_profiles (profile_id, agency_id)
    values (v_request.host_id, v_request.agency_id)
    on conflict (profile_id) do nothing;

    insert into public.host_grants (profile_id, agency_id, granted_by, code_id)
    values (v_request.host_id, v_request.agency_id, auth.uid(), null);

    perform public.sync_host_flag(v_request.host_id);
  end if;
end;
$$;

grant execute on function public.decide_live_request(uuid, boolean) to authenticated;

-- Lets the app's go-live gate show "request sent, waiting for <agency>" (or
-- "declined by <agency>") without a second round trip — reports the most
-- recent go_live_approval request's status/agency alongside the existing
-- access fields.
create or replace function public.my_host_access()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_grant public.host_grants;
  v_banned boolean;
  v_pending record;
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

  select lr.status, a.name as agency_name into v_pending
  from public.live_requests lr
  join public.agencies a on a.id = lr.agency_id
  where lr.host_id = v_me and lr.type = 'go_live_approval'
  order by lr.created_at desc
  limit 1;

  return jsonb_build_object(
    'has_access', v_grant.id is not null,
    'expires_at', v_grant.expires_at,
    'banned', coalesce(v_banned, false),
    'request_status', v_pending.status,
    'request_agency_name', v_pending.agency_name
  );
end;
$$;

-- Extend the agency-staff policies from 20260930090000 to also match
-- agency_id directly — a freshly-filed request has no host_profiles row
-- yet (that only gets created on approval), so the old host_profiles-
-- derived check alone would never show a brand new request to the agency
-- that needs to act on it.
drop policy "Agency staff see their hosts' live requests" on public.live_requests;
create policy "Agency staff see their hosts' live requests"
  on public.live_requests for select
  using (
    (agency_id is not null and public.manages_agency(agency_id))
    or exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = live_requests.host_id
        and public.manages_agency(hp.agency_id)
    )
  );

drop policy "Agency staff review their hosts' live requests" on public.live_requests;
create policy "Agency staff review their hosts' live requests"
  on public.live_requests for update
  using (
    (agency_id is not null and public.manages_agency(agency_id))
    or exists (
      select 1 from public.host_profiles hp
      where hp.profile_id = live_requests.host_id
        and public.manages_agency(hp.agency_id)
    )
  );
