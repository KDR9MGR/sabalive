-- Account deletion requests, required by Google Play's Data safety /
-- Account deletion policy and Apple App Store Guideline 5.1.1(v): apps that
-- support account creation must offer a way to request deletion of the
-- account and its data, reachable both in-app and via a public web page
-- that works without installing or signing into the app.
--
-- This table is the queue both paths write into. Actual deletion (or
-- anonymization) of the profile/auth user is a manual admin-panel action
-- for now, matching the existing "handled manually within 7 days" promise
-- already shown in the app's Delete Account dialog.
create table public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles (id),
  email text not null,
  reason text,
  source text not null default 'app' check (source in ('app', 'web')),
  status text not null default 'pending' check (status in ('pending', 'completed', 'rejected')),
  requested_at timestamptz not null default now(),
  processed_at timestamptz,
  processed_by uuid references public.profiles (id)
);

alter table public.account_deletion_requests enable row level security;

create policy "Staff manage deletion requests"
  on public.account_deletion_requests for select
  using (public.is_admin_or_above());
create policy "Staff update deletion requests"
  on public.account_deletion_requests for update
  using (public.is_admin_or_above());

-- A signed-in user, called from the in-app "Delete account" flow. Always
-- resolves identity from auth.uid()/auth.jwt(), never from client input.
create function public.request_account_deletion(p_reason text default null)
returns public.account_deletion_requests
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_email text;
  v_row public.account_deletion_requests;
begin
  if v_user is null then
    raise exception 'Must be signed in to request account deletion';
  end if;

  v_email := coalesce(auth.jwt() ->> 'email', '');

  insert into public.account_deletion_requests (profile_id, email, reason, source)
  values (v_user, v_email, p_reason, 'app')
  returning * into v_row;

  return v_row;
end;
$$;

revoke execute on function public.request_account_deletion(text) from public;
grant execute on function public.request_account_deletion(text) to authenticated;
