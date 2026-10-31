-- WRITES. Run only through scripts/prod/follow_everyone.sh --apply (placeholders __DISPLAY_ID__ and __STAMP__ are replaced by the script).
-- Makes every eligible account follow the target AND the target follow every eligible account (so each pair are also Fans), once, silently.
--
--   * One transaction: any error and nothing is kept. The row-by-row triggers on `follows` are switched off for THIS transaction only
--     (`set local session_replication_role = replica`: it ends with the transaction, nothing stays disabled): no "started following you"
--     notification and no push, and no O(N x N) fans recount. The three counters the triggers keep (followers_count, following_count,
--     fans_count) are then moved here in one pass each, for exactly the rows this run added.
--   * Every row this run adds carries created_at = __STAMP__ (the same value), which is how follow_everyone.sh --undo finds exactly them.
--     A follow that already existed is left alone (on conflict do nothing) and is not undone.
--   * Eligible = the rules in follow_everyone_plan.sql (active, not ghost, not staff, no active account / device ban, no block either way).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local session_replication_role = replica;

create temp table _t on commit drop as
  select id from public.profiles where display_id = __DISPLAY_ID__ and not coalesce(is_ghost, false);
do $$
begin
  if (select count(*) from _t) <> 1 then
    raise exception 'follow_everyone: User ID __DISPLAY_ID__ was not found (or it is a monitoring account). Nothing was changed.';
  end if;
end $$;

create temp table _c on commit drop as
  select p.id
    from public.profiles p, _t t
   where p.id <> t.id
     and p.status = 'active'
     and not coalesce(p.is_ghost, false)
     and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
     and not exists (select 1 from public.user_bans b
                      where b.user_id = p.id and b.kind in ('account', 'device') and b.lifted_at is null
                        and b.starts_at <= now() and (b.ends_at is null or b.ends_at > now()))
     and not exists (select 1 from public.blocks k
                      where (k.blocker_id = p.id and k.blocked_id = t.id) or (k.blocker_id = t.id and k.blocked_id = p.id));

create temp table _new (follower_id uuid not null, followee_id uuid not null) on commit drop;

-- everyone follows the target
with ins as (
  insert into public.follows (follower_id, followee_id, created_at)
  select c.id, t.id, timestamptz '__STAMP__' from _c c, _t t
  on conflict do nothing
  returning follower_id, followee_id
)
insert into _new select follower_id, followee_id from ins;

-- the target follows everyone
with ins as (
  insert into public.follows (follower_id, followee_id, created_at)
  select t.id, c.id, timestamptz '__STAMP__' from _c c, _t t
  on conflict do nothing
  returning follower_id, followee_id
)
insert into _new select follower_id, followee_id from ins;

-- the counters the triggers would have moved, once per person
update public.profiles p set followers_count = p.followers_count + n.c
  from (select followee_id as id, count(*)::int as c from _new group by 1) n
 where p.id = n.id;
update public.profiles p set following_count = p.following_count + n.c
  from (select follower_id as id, count(*)::int as c from _new group by 1) n
 where p.id = n.id;
-- Fans (people who follow each other) are re-counted from `follows`, exactly as the fans trigger does
with who as (select follower_id as id from _new union select followee_id from _new),
cnt as (
  select w.id, (select count(*)::int
                  from public.follows a
                  join public.follows b on b.follower_id = a.followee_id and b.followee_id = a.follower_id
                 where a.follower_id = w.id) as n
    from who w
)
update public.profiles p set fans_count = cnt.n
  from cnt
 where p.id = cnt.id and p.fans_count is distinct from cnt.n;
commit;

-- what was done (read after the commit)
select jsonb_build_object(
  'stamp', '__STAMP__',
  'added_everyone_follows_target', (select count(*) from public.follows where created_at = timestamptz '__STAMP__' and followee_id = (select id from public.profiles where display_id = __DISPLAY_ID__)),
  'added_target_follows_everyone', (select count(*) from public.follows where created_at = timestamptz '__STAMP__' and follower_id = (select id from public.profiles where display_id = __DISPLAY_ID__)),
  'target_followers_now', (select followers_count from public.profiles where display_id = __DISPLAY_ID__),
  'target_following_now', (select following_count from public.profiles where display_id = __DISPLAY_ID__),
  'target_fans_now', (select fans_count from public.profiles where display_id = __DISPLAY_ID__),
  'counters_that_disagree_with_follows', (
    select count(*) from public.profiles p
     where p.id in (select follower_id from public.follows where created_at = timestamptz '__STAMP__'
                    union select followee_id from public.follows where created_at = timestamptz '__STAMP__')
       and (p.followers_count <> (select count(*) from public.follows f where f.followee_id = p.id)
         or p.following_count <> (select count(*) from public.follows f where f.follower_id = p.id)))
) as report;
