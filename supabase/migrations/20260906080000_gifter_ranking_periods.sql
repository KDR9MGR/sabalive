-- Gifter (top-spender) leaderboards for the daily and weekly periods, to
-- match the host leaderboards which already have all three periods. Same
-- SECURITY DEFINER pattern as the existing rankings_* functions.

create function public.rankings_top_gifters_weekly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('week', now())
  group by sender_id
  order by score desc;
$$;

create function public.rankings_top_gifters_daily()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('day', now())
  group by sender_id
  order by score desc;
$$;

grant execute on function
  public.rankings_top_gifters_weekly(),
  public.rankings_top_gifters_daily()
to authenticated, anon;
