-- Temporary lockdown, requested directly: stop every agency-related
-- self-serve request coming from the app — nothing should land pending for
-- staff to act on, and nothing should slip through approved. Two entry
-- points exist; both are SECURITY DEFINER RPCs with no other path in (RLS
-- blocks a raw insert into agencies/live_requests for a non-staff caller),
-- so gating each one here fully closes it off.
--
-- apply_for_agency (20260923160000): a user applying to become a brand-new
-- agency. There's no "rejected" status for agencies (only
-- active/inactive/pending), so this is blocked outright at the door —
-- nothing is created at all.
create or replace function public.apply_for_agency(
  p_name text,
  p_holder_name text,
  p_whatsapp text,
  p_country text default 'India',
  p_reference text default null
)
returns public.agencies
language plpgsql security definer set search_path = public
as $$
begin
  raise exception 'Agency applications are temporarily paused. Contact your platform administrator.';
end;
$$;

-- request_go_live (20260930100000, status-gated in 20261001160000): a host
-- requesting to go live under an existing agency. live_requests does have a
-- 'rejected' status, so — per "even if it comes through, reject it" — this
-- still records the request (so there's a visible trail) but lands it
-- already rejected instead of pending, so it never sits in anyone's queue.
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

  insert into public.live_requests (host_id, agency_id, type, priority, status, reviewed_at)
  values (v_me, v_agency.id, 'go_live_approval', 'medium', 'rejected', now());

  return jsonb_build_object('agency_name', v_agency.name, 'status', 'rejected');
end;
$$;
