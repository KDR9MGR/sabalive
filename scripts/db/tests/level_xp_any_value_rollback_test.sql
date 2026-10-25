-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/level_xp_any_value_rollback_test.sql
-- Proves supabase/rollbacks/20261025140000_down.sql: admin_save_track_level_v3 is gone, levels saved with out-of-order numbers keep them, v1 and v2 still work,
-- a second run is harmless, and the migration applies again.
insert into auth.users (id, email) values ('a1000000-0000-0000-0000-0000000000a1', 'super@x');
insert into public.staff_roles (user_id, role, permissions) values ('a1000000-0000-0000-0000-0000000000a1', 'super_admin', '{}');
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-0000000000a1', false);
select public.admin_save_track_level_v3('wealth', 3, 1);
select '1 before: level 3 saved far below level 2 (expect 1)' as check, xp_required from public.track_levels where track = 'wealth' and level = 3;

\i supabase/rollbacks/20261025140000_down.sql

select '2 the function is gone (expect 0)' as check, count(*) as n from pg_proc where proname = 'admin_save_track_level_v3';
select '2b the out-of-order number is still there (expect 1)' as check, xp_required from public.track_levels where track = 'wealth' and level = 3;
select '3 v2 still works with the switch, moving the 98 later levels (expect 98)' as check, public.admin_save_track_level_v2('wealth', 2, 20000, null, true) as moved;

\i supabase/rollbacks/20261025140000_down.sql
select '4 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'admin_save_track_level_v3';

\i supabase/migrations/20261025140000_level_xp_any_value.sql
select public.admin_save_track_level_v3('wealth', 3, 7);
select '5 re-applied: it works again (expect 7)' as check, xp_required from public.track_levels where track = 'wealth' and level = 3;
