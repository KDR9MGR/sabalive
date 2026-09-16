-- Public leaderboards derived from gift_transactions. gift_transactions
-- itself is only visible to the sender/receiver/staff (it's someone's
-- spending history), but a leaderboard of *totals* is meant to be public —
-- these views run with the privileges of their owner (created here as the
-- migration role, which bypasses the base table's RLS), so grant select on
-- them directly to app roles.

create view public.rankings_all_time as
select receiver_id as profile_id, sum(coins)::bigint as score
from public.gift_transactions
group by receiver_id;

create view public.rankings_monthly as
select receiver_id as profile_id, sum(coins)::bigint as score
from public.gift_transactions
where created_at >= date_trunc('month', now())
group by receiver_id;

create view public.rankings_weekly as
select receiver_id as profile_id, sum(coins)::bigint as score
from public.gift_transactions
where created_at >= date_trunc('week', now())
group by receiver_id;

create view public.rankings_daily as
select receiver_id as profile_id, sum(coins)::bigint as score
from public.gift_transactions
where created_at >= date_trunc('day', now())
group by receiver_id;

-- Gifters leaderboard (who spends the most, not who earns the most).
create view public.rankings_top_gifters_monthly as
select sender_id as profile_id, sum(coins)::bigint as score
from public.gift_transactions
where created_at >= date_trunc('month', now())
group by sender_id;

grant select on
  public.rankings_all_time,
  public.rankings_monthly,
  public.rankings_weekly,
  public.rankings_daily,
  public.rankings_top_gifters_monthly
to authenticated, anon;
