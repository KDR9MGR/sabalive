-- Self-serve "Apply for Agency" — agencies.status already defaulted to
-- 'pending' from the original schema (built for exactly this, never
-- wired up client-side). INSERT on agencies is admin-only via RLS
-- ("Only admins manage agencies"), so this needs a SECURITY DEFINER RPC
-- rather than a raw client insert — the applicant becomes manager_id,
-- which the existing SELECT policy ("...or their own manager") already
-- lets them read back to check status, no new read path needed.
alter table public.agencies add column holder_name text;
alter table public.agencies add column whatsapp_number text;
alter table public.agencies add column applicant_reference text;

create function public.apply_for_agency(
  p_name text,
  p_holder_name text,
  p_whatsapp text,
  p_country text default 'India',
  p_reference text default null
)
returns public.agencies
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_row public.agencies;
begin
  if v_me is null then
    raise exception 'Must be signed in to apply';
  end if;
  if trim(coalesce(p_name, '')) = '' or trim(coalesce(p_holder_name, '')) = ''
     or trim(coalesce(p_whatsapp, '')) = '' then
    raise exception 'Agency name, holder name, and WhatsApp number are required';
  end if;
  if exists (select 1 from public.agencies where manager_id = v_me) then
    raise exception 'You already have an agency application on file';
  end if;

  insert into public.agencies
    (name, manager_id, country, holder_name, whatsapp_number, applicant_reference, status)
  values
    (p_name, v_me, coalesce(nullif(trim(p_country), ''), 'India'), p_holder_name, p_whatsapp, p_reference, 'pending')
  returning * into v_row;
  return v_row;
end;
$$;
