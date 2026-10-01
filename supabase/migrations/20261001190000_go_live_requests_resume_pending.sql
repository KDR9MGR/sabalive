-- Un-does only the request_go_live half of 20261001180000. That migration
-- paused two different things under one instruction, but they're not the
-- same story: apply_for_agency (applying to BECOME a new agency) stays
-- fully blocked. request_go_live (a host asking to join an EXISTING,
-- already-approved agency) should go back to sitting pending for that
-- agency/staff to actually review via decide_live_request — auto-rejecting
-- it meant a legitimate host joining a real agency could never get through
-- even with a human looking. The agency-must-be-active gate (20261001160000)
-- stays: a request still can't target an unapproved agency.
create or replace function public.request_go_live(p_agency_display_id bigint)
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
  if v_agency.status <> 'active' then
    raise exception 'This agency has not been approved yet — its ID is not valid until a platform admin reviews it';
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
