-- Username doubles as the lookup key for coin transfers (resell_coins) and
-- is meant to be admin/agency-controlled, not user-editable — removing the
-- field from the app's Edit Profile screen isn't enough on its own, since
-- "Users can update their own profile" is a blanket owner-update RLS
-- policy with no per-column restriction; a direct API call could still
-- change it. Silently reverts any attempted change from a non-staff
-- caller rather than erroring, so it doesn't break unrelated profile
-- field updates that happen to include the unchanged username.
create function public.protect_username()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.username is distinct from old.username and not public.is_staff() then
    new.username := old.username;
  end if;
  return new;
end;
$$;

create trigger protect_username_trigger
before update on public.profiles
for each row execute function public.protect_username();
