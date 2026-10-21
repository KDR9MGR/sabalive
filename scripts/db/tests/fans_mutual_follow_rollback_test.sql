-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/fans_mutual_follow_rollback_test.sql
-- Proves supabase/rollbacks/20261021180000_down.sql: the trigger and both functions are gone, fans_count is back to 0 for everyone, the old follower
-- counts and the follows themselves are untouched; a second run is harmless; applying the migration again rebuilds the counts.
insert into auth.users (id, email) values ('f1000000-0000-0000-0000-0000000000a1', 'ra@x'), ('f2000000-0000-0000-0000-0000000000b2', 'rb@x');
insert into public.follows (follower_id, followee_id) values
  ('f1000000-0000-0000-0000-0000000000a1', 'f2000000-0000-0000-0000-0000000000b2'),
  ('f2000000-0000-0000-0000-0000000000b2', 'f1000000-0000-0000-0000-0000000000a1');
select '1 before: the pair has one fan each (expect 1, 1)' as check,
       (select fans_count from public.profiles where id = 'f1000000-0000-0000-0000-0000000000a1') as a,
       (select fans_count from public.profiles where id = 'f2000000-0000-0000-0000-0000000000b2') as b;

\i supabase/rollbacks/20261021180000_down.sql

select '2 the trigger and both functions are gone (expect 0, 0, 0)' as check,
       (select count(*) from pg_trigger where tgname = 'follows_fans_after_change') as trig,
       (select count(*) from pg_proc where proname = 'handle_fans_change') as fn,
       (select count(*) from pg_proc where proname = 'get_fans') as list;
select '3 fans_count is 0 again and the follower counts are untouched (expect 0, 0, 1, 1, 2 follows)' as check,
       (select fans_count from public.profiles where id = 'f1000000-0000-0000-0000-0000000000a1') as a,
       (select fans_count from public.profiles where id = 'f2000000-0000-0000-0000-0000000000b2') as b,
       (select followers_count from public.profiles where id = 'f1000000-0000-0000-0000-0000000000a1') as a_followers,
       (select followers_count from public.profiles where id = 'f2000000-0000-0000-0000-0000000000b2') as b_followers,
       (select count(*) from public.follows) as follows;
select '3b the old follows trigger is still there (expect 1)' as check, count(*) as n from pg_trigger where tgname = 'follows_after_change';

\i supabase/rollbacks/20261021180000_down.sql
select '4 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'get_fans';

\i supabase/migrations/20261021180000_fans_mutual_follow.sql
select '5 re-applied: the back-fill restores the pair (expect 1, 1)' as check,
       (select fans_count from public.profiles where id = 'f1000000-0000-0000-0000-0000000000a1') as a,
       (select fans_count from public.profiles where id = 'f2000000-0000-0000-0000-0000000000b2') as b;
