-- A freshly self-applied agency (apply_for_agency, 20260923160000) gets a
-- real display_id and UUID the instant it's inserted, with status='pending'
-- — but nothing downstream ever checked that status, so its ID was fully
-- usable before any platform admin reviewed it. Close that off at the one
-- place a host actually uses an agency's display_id to act on it.
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
