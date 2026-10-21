-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/profile_tags_rollback_test.sql
-- Proves supabase/rollbacks/20261021190000_down.sql: both tag tables and the four functions are gone; set_staff_permissions is back to the
-- previous version (it refuses 'manage_tags' as an unknown key and still accepts an older key); a second run is harmless; applying the
-- migration again works.
insert into auth.users (id, email) values ('a1000000-0000-0000-0000-0000000000a1', 'rsuper@x'), ('d1000000-0000-0000-0000-0000000000d1', 'rcountry@x');
insert into public.staff_roles (user_id, role) values ('a1000000-0000-0000-0000-0000000000a1', 'super_admin'), ('d1000000-0000-0000-0000-0000000000d1', 'country_admin');
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-0000000000a1', false);
select public.admin_save_profile_tag(null, 'Official', '#7c3aed', null, 'active', 1);
select '1 before: a tag exists and Access Control accepts the key (expect 1, t)' as check,
       (select count(*) from public.profile_tags) as tags,
       (public.set_staff_permissions('d1000000-0000-0000-0000-0000000000d1', '{"manage_tags": true}') ->> 'manage_tags')::boolean as granted;

\i supabase/rollbacks/20261021190000_down.sql

select '2 the tables are gone (expect 0, 0)' as check,
       (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'profile_tags') as tags,
       (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'profile_tag_assignments') as assignments;
select '2b the functions are gone (expect 0)' as check, count(*) as n from pg_proc
 where proname in ('staff_can_manage_tags', 'admin_save_profile_tag', 'admin_delete_profile_tag', 'admin_set_user_tags');
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
select '3 Access Control is back to the old key list: manage_tags is unknown, an old key works (expect t, t)' as check,
       pg_temp.refused('select public.set_staff_permissions(''d1000000-0000-0000-0000-0000000000d1'', ''{"manage_tags": true}'')', 'Unknown permission%') as unknown_key,
       (public.set_staff_permissions('d1000000-0000-0000-0000-0000000000d1', '{"view_user_profile": true}') ->> 'view_user_profile')::boolean as old_key;

\i supabase/rollbacks/20261021190000_down.sql
select '4 a second rollback is harmless (expect 0)' as check, count(*) as n from information_schema.tables where table_schema = 'public' and table_name = 'profile_tags';

\i supabase/migrations/20261021190000_profile_tags.sql
select '5 re-applied: it works again (expect Official, t)' as check, (public.admin_save_profile_tag(null, 'Official', '#7c3aed', null, 'active', 1)).name as name,
       (public.set_staff_permissions('d1000000-0000-0000-0000-0000000000d1', '{"manage_tags": true}') ->> 'manage_tags')::boolean as granted;
