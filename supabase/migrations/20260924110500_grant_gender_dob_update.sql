-- The original column-scoped UPDATE grant on profiles
-- (20260905090000_roles_agencies_hosts.sql) only lists
-- (name, username, bio, location, avatar_url). Adding a column doesn't
-- extend a column-scoped grant automatically, so without this, self-editing
-- gender/date_of_birth from the client fails with a permission error even
-- though RLS allows the row.
grant update (gender, date_of_birth) on public.profiles to authenticated;
