-- Fans = people who follow each other (A follows B AND B follows A). The profile already had a "Fans" number (profiles.fans_count) but
-- nothing ever changed it, so it was always 0. This keeps it right and adds the list behind it.
--
--   handle_fans_change()   a second, separate trigger on follows (the existing follows_after_change trigger and its function are NOT touched).
--                          After a follow that completes a pair, or after ANY unfollow, it re-counts the two people involved from the follows
--                          table itself, so a count can never drift (a deleted account's cascade included) and a repeat run changes nothing.
--   get_fans(user, limit)  the people in a user's Fans list, newest pair first; runs as the caller, so the profiles rules still hide ghosts.
--   one-off back-fill      the people who already follow each other get their count now.
--
-- Additive only: old app builds read fans_count as before (they only ever saw 0). Rollback: supabase/rollbacks/20261021180000_down.sql.
set local lock_timeout = '5s';

create or replace function public.handle_fans_change()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_a uuid;
  v_b uuid;
begin
  if tg_op = 'INSERT' then
    v_a := new.follower_id;
    v_b := new.followee_id;
    -- a follow only makes a fan pair when the other person already follows back
    if not exists (select 1 from public.follows f where f.follower_id = v_b and f.followee_id = v_a) then
      return null;
    end if;
  else
    v_a := old.follower_id;
    v_b := old.followee_id;
  end if;

  update public.profiles p
     set fans_count = c.n
    from (
      select u.id, (select count(*)::int
                      from public.follows a
                      join public.follows b on b.follower_id = a.followee_id and b.followee_id = a.follower_id
                     where a.follower_id = u.id) as n
        from (select v_a as id union select v_b) u
    ) c
   where p.id = c.id and p.fans_count is distinct from c.n;
  return null;
end;
$$;
revoke execute on function public.handle_fans_change() from public, anon, authenticated;

drop trigger if exists follows_fans_after_change on public.follows;
create trigger follows_fans_after_change
  after insert or delete on public.follows
  for each row execute function public.handle_fans_change();

create or replace function public.get_fans(p_user uuid, p_limit integer default 200)
returns setof public.profiles
language sql stable security invoker set search_path = public
as $$
  select p.*
    from public.follows a
    join public.follows b on b.follower_id = a.followee_id and b.followee_id = a.follower_id
    join public.profiles p on p.id = a.followee_id
   where a.follower_id = p_user
   order by greatest(a.created_at, b.created_at) desc, p.id
   limit least(greatest(coalesce(p_limit, 200), 1), 500);
$$;
revoke execute on function public.get_fans(uuid, integer) from public, anon;
grant execute on function public.get_fans(uuid, integer) to authenticated;

-- back-fill: only people who already have at least one mutual follow need a change (everyone else is correctly 0)
update public.profiles p
   set fans_count = c.n
  from (
    select a.follower_id as id, count(*)::int as n
      from public.follows a
      join public.follows b on b.follower_id = a.followee_id and b.followee_id = a.follower_id
     group by a.follower_id
  ) c
 where p.id = c.id and p.fans_count is distinct from c.n;
