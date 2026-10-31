-- WRITES. Run only through scripts/prod/follow_everyone.sh --undo "<stamp>" (placeholders __DISPLAY_ID__ and __STAMP__ are replaced by the script).
-- Removes exactly the follows that one --apply run added (created_at = __STAMP__, and the target is on one side), then puts the three counters back.
-- A follow that existed before the run (or that someone made later) has another created_at and is never touched. Silent, one transaction, triggers off for it only.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
set local session_replication_role = replica;

create temp table _t on commit drop as select id from public.profiles where display_id = __DISPLAY_ID__;
do $$
begin
  if (select count(*) from _t) <> 1 then
    raise exception 'follow_everyone --undo: User ID __DISPLAY_ID__ was not found. Nothing was changed.';
  end if;
end $$;

create temp table _gone (follower_id uuid not null, followee_id uuid not null) on commit drop;
with del as (
  delete from public.follows f
   using _t t
   where f.created_at = timestamptz '__STAMP__' and (f.follower_id = t.id or f.followee_id = t.id)
  returning f.follower_id, f.followee_id
)
insert into _gone select follower_id, followee_id from del;

update public.profiles p set followers_count = greatest(p.followers_count - n.c, 0)
  from (select followee_id as id, count(*)::int as c from _gone group by 1) n
 where p.id = n.id;
update public.profiles p set following_count = greatest(p.following_count - n.c, 0)
  from (select follower_id as id, count(*)::int as c from _gone group by 1) n
 where p.id = n.id;
with who as (select follower_id as id from _gone union select followee_id from _gone),
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

select jsonb_build_object(
  'stamp', '__STAMP__',
  'rows_left_with_this_stamp', (select count(*) from public.follows where created_at = timestamptz '__STAMP__'),
  'target_followers_now', (select followers_count from public.profiles where display_id = __DISPLAY_ID__),
  'target_following_now', (select following_count from public.profiles where display_id = __DISPLAY_ID__),
  'target_fans_now', (select fans_count from public.profiles where display_id = __DISPLAY_ID__)
) as report;
