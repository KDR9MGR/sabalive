-- Down script for supabase/migrations/20261006130000_set_staff_permissions.sql
-- Applied BY HAND only. Cannot be undone: permissions already saved through the function (they stay in
-- staff_roles.permissions) and the 'staff.permissions_changed' audit rows.
begin;
set local lock_timeout = '5s';
drop function if exists public.set_staff_permissions(uuid, jsonb);
commit;
