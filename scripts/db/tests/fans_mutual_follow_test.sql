-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/fans_mutual_follow_test.sql
-- Proves (20261021180000): fans_count is the number of people who follow each other; a one-way follow changes nothing; an unfollow takes the
-- pair apart on both sides; deleting an account re-counts the person it was paired with; get_fans lists exactly the pairs; the back-fill
-- statement repairs a wrong count; the trigger function is not callable by app users.
insert into auth.users (id, email) values
  ('f5000000-0000-0000-0000-00000000000e', 'fe@x'),
  ('f6000000-0000-0000-0000-00000000000f', 'ff@x'),
  ('f1000000-0000-0000-0000-00000000000a', 'fa@x'),
  ('f2000000-0000-0000-0000-00000000000b', 'fb@x'),
  ('f3000000-0000-0000-0000-00000000000c', 'fc@x'),
  ('f4000000-0000-0000-0000-00000000000d', 'fd@x');

create or replace function pg_temp.fans(p_id text) returns int language sql as $$
  select fans_count from public.profiles where id = p_id::uuid;
$$;
create or replace function pg_temp.refused_as(p_user text, p_sql text) returns boolean language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_user, false);
  set local role authenticated;
  begin execute p_sql; reset role; return false; exception when others then reset role; return true; end;
end $$;
create or replace function pg_temp.follow(p_who text, p_whom text) returns void language sql as $$
  insert into public.follows (follower_id, followee_id) values (p_who::uuid, p_whom::uuid);
$$;

-- 1. A follows B: one way only, nobody is a fan yet
select pg_temp.follow('f1000000-0000-0000-0000-00000000000a', 'f2000000-0000-0000-0000-00000000000b');
select '1 a one-way follow makes no fans (expect 0, 0)' as check,
       pg_temp.fans('f1000000-0000-0000-0000-00000000000a') as a, pg_temp.fans('f2000000-0000-0000-0000-00000000000b') as b;

-- 2. B follows A back: both are fans of each other
select pg_temp.follow('f2000000-0000-0000-0000-00000000000b', 'f1000000-0000-0000-0000-00000000000a');
select '2 following back makes a pair (expect 1, 1)' as check,
       pg_temp.fans('f1000000-0000-0000-0000-00000000000a') as a, pg_temp.fans('f2000000-0000-0000-0000-00000000000b') as b;

-- 3. a second pair: A and C
select pg_temp.follow('f1000000-0000-0000-0000-00000000000a', 'f3000000-0000-0000-0000-00000000000c');
select pg_temp.follow('f3000000-0000-0000-0000-00000000000c', 'f1000000-0000-0000-0000-00000000000a');
select '3 A has two fans, B and C one each (expect 2, 1, 1)' as check,
       pg_temp.fans('f1000000-0000-0000-0000-00000000000a') as a, pg_temp.fans('f2000000-0000-0000-0000-00000000000b') as b, pg_temp.fans('f3000000-0000-0000-0000-00000000000c') as c;

-- 4. D follows A and A does not follow back: nothing changes
select pg_temp.follow('f4000000-0000-0000-0000-00000000000d', 'f1000000-0000-0000-0000-00000000000a');
select '4 an unreturned follow changes nothing (expect 2, 0)' as check,
       pg_temp.fans('f1000000-0000-0000-0000-00000000000a') as a, pg_temp.fans('f4000000-0000-0000-0000-00000000000d') as d;

-- 5. the followers / following counts the old trigger keeps are still right (A: followers B, C, D = 3; following B, C = 2)
select '5 the old follower counts are untouched (expect 3, 2)' as check,
       (select followers_count from public.profiles where id = 'f1000000-0000-0000-0000-00000000000a') as followers,
       (select following_count from public.profiles where id = 'f1000000-0000-0000-0000-00000000000a') as following;

-- 6. get_fans(A) lists B and C, not D, newest pair first (C completed the pair after B)
select '6 the list is B and C only, newest pair first (expect 2, f3, f2)' as check,
       (select count(*) from public.get_fans('f1000000-0000-0000-0000-00000000000a')) as n,
       (select left(id::text, 2) from public.get_fans('f1000000-0000-0000-0000-00000000000a') limit 1) as first_one,
       (select left(id::text, 2) from public.get_fans('f1000000-0000-0000-0000-00000000000a') offset 1 limit 1) as second_one;
select '6b D has no fans, so the list is empty (expect 0)' as check, count(*) as n from public.get_fans('f4000000-0000-0000-0000-00000000000d');
select '6c the limit is honoured (expect 1)' as check, count(*) as n from public.get_fans('f1000000-0000-0000-0000-00000000000a', 1);

-- 7. A unfollows B: the pair is gone on both sides
delete from public.follows where follower_id = 'f1000000-0000-0000-0000-00000000000a' and followee_id = 'f2000000-0000-0000-0000-00000000000b';
select '7 an unfollow takes the pair apart (expect 1, 0)' as check,
       pg_temp.fans('f1000000-0000-0000-0000-00000000000a') as a, pg_temp.fans('f2000000-0000-0000-0000-00000000000b') as b;

-- 8. A follows B again: the pair is back
select pg_temp.follow('f1000000-0000-0000-0000-00000000000a', 'f2000000-0000-0000-0000-00000000000b');
select '8 following again restores it (expect 2, 1)' as check,
       pg_temp.fans('f1000000-0000-0000-0000-00000000000a') as a, pg_temp.fans('f2000000-0000-0000-0000-00000000000b') as b;

-- 9. C's account is deleted (cascade removes both follow rows): A is re-counted to the one pair left
delete from public.profiles where id = 'f3000000-0000-0000-0000-00000000000c';
select '9 deleting an account re-counts the other side (expect 1)' as check, pg_temp.fans('f1000000-0000-0000-0000-00000000000a') as a;

-- 10. a wrong count is repaired by the back-fill statement of the migration
update public.profiles set fans_count = 99 where id = 'f1000000-0000-0000-0000-00000000000a';
update public.profiles p
   set fans_count = c.n
  from (
    select a.follower_id as id, count(*)::int as n
      from public.follows a
      join public.follows b on b.follower_id = a.followee_id and b.followee_id = a.follower_id
     group by a.follower_id
  ) c
 where p.id = c.id and p.fans_count is distinct from c.n;
select '10 the back-fill repairs it (expect 1)' as check, pg_temp.fans('f1000000-0000-0000-0000-00000000000a') as a;

-- 11. permissions
select '11 the trigger function is not callable by app users, the list is for signed-in users only (expect f, f, f, t)' as check,
       has_function_privilege('anon', 'public.handle_fans_change()', 'execute') as anon_trigger,
       has_function_privilege('authenticated', 'public.handle_fans_change()', 'execute') as authed_trigger,
       has_function_privilege('anon', 'public.get_fans(uuid,integer)', 'execute') as anon_list,
       has_function_privilege('authenticated', 'public.get_fans(uuid,integer)', 'execute') as authed_list;

-- 12. THE REAL APP PATH: ordinary signed-in users (role authenticated, row-level security on) following and unfollowing, exactly as the Play app does.
-- The trigger must not change what they are allowed to do or break the follow.
select set_config('request.jwt.claim.sub', 'f5000000-0000-0000-0000-00000000000e', false);
set role authenticated;
insert into public.follows (follower_id, followee_id) values ('f5000000-0000-0000-0000-00000000000e', 'f6000000-0000-0000-0000-00000000000f');
select set_config('request.jwt.claim.sub', 'f6000000-0000-0000-0000-00000000000f', false);
insert into public.follows (follower_id, followee_id) values ('f6000000-0000-0000-0000-00000000000f', 'f5000000-0000-0000-0000-00000000000e');
reset role;
select '12 two signed-in users following each other become fans (expect 1, 1)' as check,
       pg_temp.fans('f5000000-0000-0000-0000-00000000000e') as e, pg_temp.fans('f6000000-0000-0000-0000-00000000000f') as f;
select '12b the old follower counts moved too (expect 1, 1, 1, 1)' as check,
       (select followers_count from public.profiles where id = 'f5000000-0000-0000-0000-00000000000e') as e_followers,
       (select following_count from public.profiles where id = 'f5000000-0000-0000-0000-00000000000e') as e_following,
       (select followers_count from public.profiles where id = 'f6000000-0000-0000-0000-00000000000f') as f_followers,
       (select following_count from public.profiles where id = 'f6000000-0000-0000-0000-00000000000f') as f_following;
select set_config('request.jwt.claim.sub', 'f5000000-0000-0000-0000-00000000000e', false);
set role authenticated;
delete from public.follows where follower_id = 'f5000000-0000-0000-0000-00000000000e' and followee_id = 'f6000000-0000-0000-0000-00000000000f';
reset role;
select '12c an ordinary user unfollowing takes the pair apart (expect 0, 0)' as check,
       pg_temp.fans('f5000000-0000-0000-0000-00000000000e') as e, pg_temp.fans('f6000000-0000-0000-0000-00000000000f') as f;
select '12d a user still cannot follow as somebody else (expect t)' as check, pg_temp.refused_as(
  'f5000000-0000-0000-0000-00000000000e',
  'insert into public.follows (follower_id, followee_id) values (''f6000000-0000-0000-0000-00000000000f'', ''f1000000-0000-0000-0000-00000000000a'')') as ok;
