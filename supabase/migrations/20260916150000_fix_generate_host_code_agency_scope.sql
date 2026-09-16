-- Bug: generate_host_code() always attributed a new code to the CALLER's
-- own staff_roles.agency_id, ignoring whichever agency was selected in the
-- Agency panel's picker. For an admin/super_admin (whose own agency_id is
-- null, since that role is platform-wide) this meant the code always got
-- inserted with agency_id = null, then vanished from the panel's own list
-- view a moment later, because that view is filtered to the picked agency
-- (`listHostCodes(agencyId)` -> `.eq('agency_id', agencyId)`). The code was
-- never actually lost, just invisible from where it was created.
--
-- Fix: accept an explicit p_agency_id. An agency_manager/sub_admin is still
-- forced onto their own agency (current_agency_id()) regardless of what's
-- passed, so they can never mis-attribute a code to a different agency;
-- an admin/super_admin may target a specific agency (matching whichever
-- one is selected in the picker) or omit it for a platform-wide code.
create or replace function public.generate_host_code(
  p_expires_at timestamptz,
  p_label text default null,
  p_max_uses integer default 1,
  p_agency_id uuid default null
) returns public.host_codes
language plpgsql security definer set search_path = public
as $$
declare
  v_code text;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_row public.host_codes;
  v_agency_id uuid;
  i integer;
begin
  if not public.is_staff() then
    raise exception 'Only staff can generate host codes';
  end if;
  perform public.require_capability('manage_hosts');
  if p_expires_at is null or p_expires_at <= now() then
    raise exception 'Expiry must be in the future';
  end if;
  if coalesce(p_max_uses, 1) < 1 or coalesce(p_max_uses, 1) > 500 then
    raise exception 'max_uses must be 1..500';
  end if;

  if public.current_staff_role() in ('agency_manager', 'sub_admin') then
    v_agency_id := public.current_agency_id();
  elsif p_agency_id is not null then
    if not exists (select 1 from public.agencies where id = p_agency_id) then
      raise exception 'Agency not found';
    end if;
    v_agency_id := p_agency_id;
  else
    v_agency_id := null;
  end if;

  loop
    v_code := '';
    for i in 1..8 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.host_codes where code = v_code);
  end loop;

  insert into public.host_codes (code, agency_id, created_by, label, max_uses, expires_at)
  values (v_code, v_agency_id, auth.uid(),
          nullif(trim(p_label), ''), coalesce(p_max_uses, 1), p_expires_at)
  returning * into v_row;
  return v_row;
end;
$$;

grant execute on function public.generate_host_code(timestamptz, text, integer, uuid) to authenticated;
