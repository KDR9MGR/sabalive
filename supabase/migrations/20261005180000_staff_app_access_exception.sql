-- Staff accounts are kept out of the mobile app (20261002090000). This lets one
-- specific account through: app_metadata.staff_app_access = true, which the app's
-- StaffAccountGate honours. app_metadata is server-controlled, so only this kind of
-- statement can grant it. The sync_staff_app_flag trigger only touches `is_staff`,
-- so the allowance survives role grants and revokes. Idempotent.
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"staff_app_access": true}'::jsonb
 where lower(email) = 'sabap6709@gmail.com';
