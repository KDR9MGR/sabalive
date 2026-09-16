-- KYC review for the sabaliveadmin panel. kyc_verifications rows are
-- self-inserted by the consumer app; an admin approving one has to touch
-- three tables at once (the record, profiles.verified, and
-- host_profiles.kyc_status), so it goes through one function rather than a
-- direct UPDATE — same shape as decide_transfer_request / decide_withdrawal.

create function public.decide_kyc(p_verification_id uuid, p_approve boolean)
returns public.kyc_verifications
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.kyc_verifications;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can decide KYC verifications';
  end if;

  select * into v_row from public.kyc_verifications
    where id = p_verification_id and status = 'pending';
  if v_row.id is null then
    raise exception 'KYC verification not found or already decided';
  end if;

  update public.kyc_verifications
    set status      = case when p_approve then 'verified' else 'rejected' end,
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = p_verification_id
    returning * into v_row;

  if p_approve then
    update public.profiles set verified = true where id = v_row.profile_id;
  end if;

  -- keep the host/agency-facing kyc_status in sync when the person is a host
  update public.host_profiles
    set kyc_status = case when p_approve then 'verified' else 'rejected' end,
        updated_at = now()
    where profile_id = v_row.profile_id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(),
            case when p_approve then 'kyc.approved' else 'kyc.rejected' end,
            v_row.profile_id::text,
            'info');

  return v_row;
end;
$$;

revoke execute on function public.decide_kyc(uuid, boolean) from anon;
