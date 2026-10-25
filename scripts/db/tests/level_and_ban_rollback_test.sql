-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/level_and_ban_rollback_test.sql
-- Proves supabase/rollbacks/20261025110000_down.sql and 20261025120000_down.sql: the three new functions and user_bans.reason_visible are gone, a ban placed
-- with ban_user_v2 stays in force, the old functions still work, a second run is harmless, and both migrations apply again.
alter table auth.users add column if not exists banned_until timestamptz;
insert into auth.users (id, email) values ('a1000000-0000-0000-0000-0000000000a1', 'super@x'), ('f1000000-0000-0000-0000-0000000000f4', 'u@x');
insert into public.staff_roles (user_id, role, permissions) values ('a1000000-0000-0000-0000-0000000000a1', 'super_admin', '{}');
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-0000000000a1', false);
select '1 before: a 24 hour ban and a level save work (expect 1, 0)' as check,
       (select count(*) from public.ban_user_v2('f1000000-0000-0000-0000-0000000000f4', array['live'], '24h', 'x')) as ban,
       public.admin_save_track_level_v2('wealth', 2, 600) as shifted;

\i supabase/rollbacks/20261025120000_down.sql
\i supabase/rollbacks/20261025110000_down.sql

select '2 the three functions are gone (expect 0)' as check, count(*) as n from pg_proc where proname in ('ban_user_v2', 'check_login_access_v2', 'admin_save_track_level_v2');
select '2b the column is gone (expect 0)' as check, count(*) as n from information_schema.columns where table_schema = 'public' and table_name = 'user_bans' and column_name = 'reason_visible';
select '2c the 24 hour ban is still in force (expect 1)' as check, count(*) as n from public.user_bans where user_id = 'f1000000-0000-0000-0000-0000000000f4' and kind = 'live' and lifted_at is null and ends_at > now();
select public.admin_save_track_level('wealth', 2, 700);
select '3 the old functions still work (expect 1, t)' as check,
       (select count(*) from public.ban_user('f1000000-0000-0000-0000-0000000000f4', array['live'], '7d', 'old')) as ban,
       (select xp_required = 700 from public.track_levels where track = 'wealth' and level = 2) as level_ok;

\i supabase/rollbacks/20261025120000_down.sql
\i supabase/rollbacks/20261025110000_down.sql
select '4 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname in ('ban_user_v2', 'check_login_access_v2', 'admin_save_track_level_v2');

\i supabase/migrations/20261025110000_level_xp_free_edit.sql
\i supabase/migrations/20261025120000_ban_custom_end_and_reason.sql
select '5 re-applied: both work again (expect 1, 0)' as check,
       (select count(*) from public.ban_user_v2('f1000000-0000-0000-0000-0000000000f4', array['live'], 'custom', 'again', now() + interval '2 days')) as ban,
       public.admin_save_track_level_v2('wealth', 2, 800) as shifted;
