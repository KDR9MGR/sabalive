-- Deciding a host application has side effects the sabaliveadmin panel
-- can't do in one RLS-safe round trip: on approval it must create (or
-- re-point) the host_profiles row and flip profiles.is_host. Rejection is
-- status-only. Marking an application "under_review" stays a plain UPDATE
-- (no side effects) under the existing manages_agency() policy.

create function public.decide_host_application(p_application_id uuid, p_approve boolean)
returns public.host_applications
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.host_applications;
begin
  if not public.is_staff() then
    raise exception 'Only staff can decide host applications';
  end if;

  select * into v_row from public.host_applications
    where id = p_application_id and status in ('pending', 'under_review');
  if v_row.id is null then
    raise exception 'Host application not found or already decided';
  end if;

  -- manages_agency() already folds in is_admin_or_above(); a NULL agency
  -- (direct application) resolves to admin-only.
  if not public.manages_agency(v_row.agency_id) then
    raise exception 'Not allowed to decide this host application';
  end if;

  update public.host_applications
    set status      = case when p_approve then 'approved' else 'rejected' end,
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = p_application_id
    returning * into v_row;

  if p_approve then
    insert into public.host_profiles (profile_id, agency_id)
      values (v_row.applicant_id, v_row.agency_id)
      on conflict (profile_id)
        do update set agency_id = excluded.agency_id, updated_at = now();
    update public.profiles set is_host = true where id = v_row.applicant_id;
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(),
            case when p_approve then 'host_application.approved' else 'host_application.rejected' end,
            v_row.applicant_id::text,
            'info');

  return v_row;
end;
$$;

revoke execute on function public.decide_host_application(uuid, boolean) from anon;
