-- READ-ONLY. What scripts/prod/follow_everyone.sh would do for one person (placeholder __DISPLAY_ID__ is replaced by the script, digits only). Writes nothing.
-- "Eligible" = a real, active person: not the target, status active, not a monitoring (ghost) account, not a panel staff account, no active account / device ban,
-- and no block either way between them and the target. The same rules are in follow_everyone_apply.sql; scripts/db/tests/follow_everyone_test.sql proves the two agree.
with t as (
  select id, coalesce(is_ghost, false) as ghost, status from public.profiles where display_id = __DISPLAY_ID__
),
c as (
  select p.id
    from public.profiles p, t
   where p.id <> t.id
     and p.status = 'active'
     and not coalesce(p.is_ghost, false)
     and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
     and not exists (select 1 from public.user_bans b
                      where b.user_id = p.id and b.kind in ('account', 'device') and b.lifted_at is null
                        and b.starts_at <= now() and (b.ends_at is null or b.ends_at > now()))
     and not exists (select 1 from public.blocks k
                      where (k.blocker_id = p.id and k.blocked_id = t.id) or (k.blocker_id = t.id and k.blocked_id = p.id))
)
select jsonb_build_object(
  'target_found', (select count(*) from t),
  'target_is_ghost', (select count(*) from t where ghost),
  'accounts_in_total', (select count(*) from public.profiles),
  'eligible', (select count(*) from c),
  'will_add_everyone_follows_target', (select count(*) from c where not exists (select 1 from public.follows f where f.follower_id = c.id and f.followee_id = (select id from t))),
  'will_add_target_follows_everyone', (select count(*) from c where not exists (select 1 from public.follows f where f.followee_id = c.id and f.follower_id = (select id from t))),
  'left_out_ghosts', (select count(*) from public.profiles where coalesce(is_ghost, false)),
  'left_out_staff', (select count(*) from public.staff_roles),
  'left_out_not_active', (select count(*) from public.profiles where status <> 'active'),
  'target_followers_now', (select followers_count from public.profiles where display_id = __DISPLAY_ID__),
  'target_following_now', (select following_count from public.profiles where display_id = __DISPLAY_ID__)
) as plan;
