-- Down script for supabase/migrations/20261101020000_rankings_india_time.sql
-- Applied BY HAND only. Puts the nine ranking functions back on UTC windows (the board starts its day / week / month at 05:30 India time again) and
-- drops the helper. Nothing is stored by the rankings, so nothing else needs undoing.
begin;
set local lock_timeout = '5s';

-- ---- hosts (who receives the most)
create or replace function public.rankings_daily()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('day', now())
  group by receiver_id
  order by score desc;
$$;

create or replace function public.rankings_weekly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('week', now())
  group by receiver_id
  order by score desc;
$$;

create or replace function public.rankings_monthly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('month', now())
  group by receiver_id
  order by score desc;
$$;

-- ---- gifters (who spends the most)
create or replace function public.rankings_top_gifters_daily()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('day', now())
  group by sender_id
  order by score desc;
$$;

create or replace function public.rankings_top_gifters_weekly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('week', now())
  group by sender_id
  order by score desc;
$$;

create or replace function public.rankings_top_gifters_monthly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= date_trunc('month', now())
  group by sender_id
  order by score desc;
$$;

-- ---- agencies (all of an agency's hosts together)
create or replace function public.rankings_agencies_daily()
returns table(agency_id uuid, agency_name text, score bigint)
language sql stable security definer set search_path = public
as $$
  select a.id, a.name, sum(gt.coins)::bigint as score
  from public.gift_transactions gt
  join public.host_profiles hp on hp.profile_id = gt.receiver_id
  join public.agencies a on a.id = hp.agency_id
  where gt.created_at >= date_trunc('day', now())
  group by a.id, a.name
  order by score desc;
$$;

create or replace function public.rankings_agencies_weekly()
returns table(agency_id uuid, agency_name text, score bigint)
language sql stable security definer set search_path = public
as $$
  select a.id, a.name, sum(gt.coins)::bigint as score
  from public.gift_transactions gt
  join public.host_profiles hp on hp.profile_id = gt.receiver_id
  join public.agencies a on a.id = hp.agency_id
  where gt.created_at >= date_trunc('week', now())
  group by a.id, a.name
  order by score desc;
$$;

create or replace function public.rankings_agencies_monthly()
returns table(agency_id uuid, agency_name text, score bigint)
language sql stable security definer set search_path = public
as $$
  select a.id, a.name, sum(gt.coins)::bigint as score
  from public.gift_transactions gt
  join public.host_profiles hp on hp.profile_id = gt.receiver_id
  join public.agencies a on a.id = hp.agency_id
  where gt.created_at >= date_trunc('month', now())
  group by a.id, a.name
  order by score desc;
$$;

drop function if exists public.ist_period_start(text);
commit;
