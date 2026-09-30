-- Admin-panel "Add Admin" form wants Phone, Country and a Payment PIN
-- alongside the existing Name/Username/Email/Role. Phone and Country map
-- onto profiles (country reuses the existing `location` column — same
-- concept, just relabelled in this form); Payment PIN is new and staff-only,
-- so it lives on staff_roles, stored as a hash, never plaintext.

alter table public.profiles add column if not exists phone text;

alter table public.staff_roles add column if not exists payment_pin_hash text;
comment on column public.staff_roles.payment_pin_hash is
  'bcrypt hash of a staff member''s payment PIN, set via the invite-staff Edge Function. Never store or return the plaintext PIN.';

-- Extend the new-user trigger to also seed phone/location from signup
-- metadata when present (invite-staff passes these; the app's own signup
-- flow doesn't, so existing behaviour for regular users is unchanged).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name, username, phone, location)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', 'New Star'),
    coalesce(new.raw_user_meta_data ->> 'username', 'user_' || substr(new.id::text, 1, 8)),
    new.raw_user_meta_data ->> 'phone',
    coalesce(new.raw_user_meta_data ->> 'location', 'India')
  );
  return new;
end;
$$;
