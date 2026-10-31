-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/follow_everyone_test.sql      (look for "ALL FOLLOW_EVERYONE CHECKS PASSED"; any ERROR line is a failure)
-- Proves scripts/prod/follow_everyone_{plan,apply,undo}.sql on a scratch database: who is left out, both directions are added, nobody is notified, the three
-- counters stay equal to the follows table, a second run changes nothing, and --undo removes exactly what the run added and nothing else.
create function pg_temp.expect(label text, ok boolean) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', label; end if;
  raise notice 'ok  %', label;
end $$;

insert into auth.users (id, email) values
  ('a0000001-0000-0000-0000-000000000001', 'target@x'),
  ('a0000002-0000-0000-0000-000000000002', 'a@x'),
  ('a0000003-0000-0000-0000-000000000003', 'b@x'),
  ('a0000004-0000-0000-0000-000000000004', 'ghost@x'),
  ('a0000005-0000-0000-0000-000000000005', 'staff@x'),
  ('a0000006-0000-0000-0000-000000000006', 'suspended@x'),
  ('a0000007-0000-0000-0000-000000000007', 'banned@x'),
  ('a0000008-0000-0000-0000-000000000008', 'liftedban@x'),
  ('a0000009-0000-0000-0000-000000000009', 'blocker@x'),
  ('a000000a-0000-0000-0000-00000000000a', 'alreadyfollows@x'),
  ('a000000b-0000-0000-0000-00000000000b', 'pair1@x'),
  ('a000000c-0000-0000-0000-00000000000c', 'pair2@x');

update public.profiles set display_id = 900001 where id = 'a0000001-0000-0000-0000-000000000001';
update public.profiles set is_ghost = true where id = 'a0000004-0000-0000-0000-000000000004';
update public.profiles set status = 'suspended' where id = 'a0000006-0000-0000-0000-000000000006';
insert into public.staff_roles (user_id, role) values ('a0000005-0000-0000-0000-000000000005', 'super_admin');
insert into public.user_bans (user_id, kind) values ('a0000007-0000-0000-0000-000000000007', 'account');
insert into public.user_bans (user_id, kind, lifted_at) values ('a0000008-0000-0000-0000-000000000008', 'account', now());
insert into public.blocks (blocker_id, blocked_id) values ('a0000009-0000-0000-0000-000000000009', 'a0000001-0000-0000-0000-000000000001');
-- made the normal way, so every counter is right before the run: one person already follows the target, two follow each other
insert into public.follows (follower_id, followee_id, created_at) values
  ('a000000a-0000-0000-0000-00000000000a', 'a0000001-0000-0000-0000-000000000001', '2026-01-01 00:00:00+00'),
  ('a000000b-0000-0000-0000-00000000000b', 'a000000c-0000-0000-0000-00000000000c', '2026-01-01 00:00:00+00'),
  ('a000000c-0000-0000-0000-00000000000c', 'a000000b-0000-0000-0000-00000000000b', '2026-01-01 00:00:00+00');

create temp table snap as select id, followers_count, following_count, fans_count from public.profiles;
create temp table snap_follows as select follower_id, followee_id, created_at from public.follows;
select count(*) as notifications_before from public.notifications where kind = 'follow' \gset

-- eligible: a, b, liftedban, alreadyfollows, pair1, pair2 = 6.  left out: target itself, ghost, staff, suspended, banned, blocker
\! sed -e 's/__DISPLAY_ID__/900001/g' -e 's/^) as plan;/) as plan \\gset/' scripts/prod/follow_everyone_plan.sql > /tmp/ff_plan.sql
\i /tmp/ff_plan.sql
select pg_temp.expect('plan: the target is found', (:'plan'::jsonb ->> 'target_found') = '1');
select pg_temp.expect('plan: 6 eligible accounts', (:'plan'::jsonb ->> 'eligible') = '6');
select pg_temp.expect('plan: will add 5 + 6 follows (one already follows the target)',
  (:'plan'::jsonb ->> 'will_add_everyone_follows_target') = '5' and (:'plan'::jsonb ->> 'will_add_target_follows_everyone') = '6');

-- a User ID that does not exist changes nothing
\! sed -e 's/__DISPLAY_ID__/123/g' -e "s/__STAMP__/2026-10-31 10:00:00+00/g" scripts/prod/follow_everyone_apply.sql > /tmp/ff_apply_missing.sql
\i /tmp/ff_apply_missing.sql
rollback;
select pg_temp.expect('a missing User ID adds nothing', (select count(*) from public.follows) = (select count(*) from snap_follows));
-- the ghost cannot be the target either
update public.profiles set display_id = 900004 where id = 'a0000004-0000-0000-0000-000000000004';
\! sed -e 's/__DISPLAY_ID__/900004/g' -e "s/__STAMP__/2026-10-31 10:00:00+00/g" scripts/prod/follow_everyone_apply.sql > /tmp/ff_apply_ghost.sql
\i /tmp/ff_apply_ghost.sql
rollback;
select pg_temp.expect('a monitoring account as the target adds nothing', (select count(*) from public.follows) = (select count(*) from snap_follows));

-- the run
\! sed -e 's/__DISPLAY_ID__/900001/g' -e "s/__STAMP__/2026-10-31 10:00:00+00/g" -e 's/^) as report;/) as report \\gset/' scripts/prod/follow_everyone_apply.sql > /tmp/ff_apply.sql
\i /tmp/ff_apply.sql
select pg_temp.expect('apply: 5 followers added', (:'report'::jsonb ->> 'added_everyone_follows_target') = '5');
select pg_temp.expect('apply: 6 followings added', (:'report'::jsonb ->> 'added_target_follows_everyone') = '6');
select pg_temp.expect('target followers = 6 (5 new + 1 before)', (:'report'::jsonb ->> 'target_followers_now') = '6');
select pg_temp.expect('target following = 6', (:'report'::jsonb ->> 'target_following_now') = '6');
select pg_temp.expect('target fans = 6 (everyone eligible follows back)', (:'report'::jsonb ->> 'target_fans_now') = '6');
select pg_temp.expect('apply: no counter disagrees with the follows table', (:'report'::jsonb ->> 'counters_that_disagree_with_follows') = '0');
select pg_temp.expect('left out: ghost, staff, suspended, banned and the blocker are not connected to the target',
  (select count(*) from public.follows f where 'a0000001-0000-0000-0000-000000000001' in (f.follower_id, f.followee_id)
     and (f.follower_id in ('a0000004-0000-0000-0000-000000000004','a0000005-0000-0000-0000-000000000005','a0000006-0000-0000-0000-000000000006','a0000007-0000-0000-0000-000000000007','a0000009-0000-0000-0000-000000000009')
       or f.followee_id in ('a0000004-0000-0000-0000-000000000004','a0000005-0000-0000-0000-000000000005','a0000006-0000-0000-0000-000000000006','a0000007-0000-0000-0000-000000000007','a0000009-0000-0000-0000-000000000009'))) = 0);
select pg_temp.expect('silent: no new-follower notification was created', (select count(*) from public.notifications where kind = 'follow') = :notifications_before);
select pg_temp.expect('the follows triggers are all enabled again',
  (select count(*) from pg_trigger where tgrelid = 'public.follows'::regclass and tgname in ('follows_after_change','follows_notify','follows_fans_after_change') and tgenabled = 'O') = 3);
select pg_temp.expect('every follower / following / fans counter equals the follows table (whole database)',
  (select count(*) from public.profiles p
    where p.followers_count <> (select count(*) from public.follows f where f.followee_id = p.id)
       or p.following_count <> (select count(*) from public.follows f where f.follower_id = p.id)
       or p.fans_count <> (select count(*) from public.follows a join public.follows b on b.follower_id = a.followee_id and b.followee_id = a.follower_id where a.follower_id = p.id)) = 0);
select pg_temp.expect('people who were not touched kept their numbers (ghost, staff, suspended, banned, blocker)',
  (select count(*) from public.profiles p join snap s using (id)
    where p.id in ('a0000004-0000-0000-0000-000000000004','a0000005-0000-0000-0000-000000000005','a0000006-0000-0000-0000-000000000006','a0000007-0000-0000-0000-000000000007','a0000009-0000-0000-0000-000000000009')
      and (p.followers_count, p.following_count, p.fans_count) is distinct from (s.followers_count, s.following_count, s.fans_count)) = 0);
select pg_temp.expect('pair1 / pair2 (mutual before) now have 2 fans each: each other + the target',
  (select count(*) from public.profiles where id in ('a000000b-0000-0000-0000-00000000000b','a000000c-0000-0000-0000-00000000000c') and fans_count = 2) = 2);

-- a second run with another stamp finds everything already there
\! sed -e 's/__DISPLAY_ID__/900001/g' -e "s/__STAMP__/2026-10-31 11:00:00+00/g" -e 's/^) as report;/) as report \\gset/' scripts/prod/follow_everyone_apply.sql > /tmp/ff_apply2.sql
\i /tmp/ff_apply2.sql
select pg_temp.expect('second run adds nothing', (:'report'::jsonb ->> 'added_everyone_follows_target') = '0' and (:'report'::jsonb ->> 'added_target_follows_everyone') = '0');
select pg_temp.expect('second run: numbers unchanged', (:'report'::jsonb ->> 'target_followers_now') = '6' and (:'report'::jsonb ->> 'target_fans_now') = '6');

-- undo the first run
\! sed -e 's/__DISPLAY_ID__/900001/g' -e "s/__STAMP__/2026-10-31 10:00:00+00/g" -e 's/^) as report;/) as report \\gset/' scripts/prod/follow_everyone_undo.sql > /tmp/ff_undo.sql
\i /tmp/ff_undo.sql
select pg_temp.expect('undo: no row left with the stamp', (:'report'::jsonb ->> 'rows_left_with_this_stamp') = '0');
select pg_temp.expect('undo: the follows table is exactly as before the run (the old follow stayed)',
  (select count(*) from (select follower_id, followee_id, created_at from public.follows except select * from snap_follows) x) = 0
  and (select count(*) from (select * from snap_follows except select follower_id, followee_id, created_at from public.follows) y) = 0);
select pg_temp.expect('undo: every counter is back to what it was',
  (select count(*) from public.profiles p join snap s using (id) where (p.followers_count, p.following_count, p.fans_count) is distinct from (s.followers_count, s.following_count, s.fans_count)) = 0);
select pg_temp.expect('undo: still silent and triggers still on',
  (select count(*) from public.notifications where kind = 'follow') = :notifications_before
  and (select count(*) from pg_trigger where tgrelid = 'public.follows'::regclass and tgname in ('follows_after_change','follows_notify','follows_fans_after_change') and tgenabled = 'O') = 3);
\echo ALL FOLLOW_EVERYONE CHECKS PASSED
