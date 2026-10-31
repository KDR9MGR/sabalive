-- Leaderboards and rankings now start their day, week and month at INDIA midnight (IST), not at UTC midnight.
--
-- WHAT WAS WRONG. Every ranking counted gifts "since date_trunc('month', now())" (and 'week', 'day'), and the database runs on UTC. So a new month
-- (or week, or day) started for the boards at 05:30 India time, not at midnight. On 1 November the Monthly host board, the Monthly gifters board and
-- the Monthly agency board were still adding the new month's gifts to OCTOBER'S totals (46,933,190 coins, 276 hosts) until 05:30 IST: the boards
-- looked as if they had not reset. Everything else on the platform that talks about a month already uses India time (Salary reports, the Lucky Box
-- day, the diamond reset), so the rankings were the odd one out.
--
-- WHAT THIS DOES. One small helper, ist_period_start('day' | 'week' | 'month'), returns the start of the current India day / Monday-based week /
-- month as an exact moment; the nine ranking functions use it. Nothing else changes: the same names, the same (no) arguments, the same columns, the
-- same gift_transactions source and the same order, so every installed app version keeps working, and the change is live for all of them the moment
-- it is applied (the boards are computed on every call; nothing is stored, so there is nothing to reset or delete). rankings_all_time is unchanged.
--   hosts:    rankings_daily / rankings_weekly / rankings_monthly
--   gifters:  rankings_top_gifters_daily / _weekly / _monthly
--   agencies: rankings_agencies_daily / _weekly / _monthly
-- The diamond reset only changes wallet balances (it never touched gift history), so it never changed these boards; they follow the calendar.
-- Rollback: supabase/rollbacks/20261101020000_down.sql (puts the UTC windows back).
set local lock_timeout = '5s';

-- the start of the current India day / week (Monday) / month, as an exact moment
create or replace function public.ist_period_start(p_unit text)
returns timestamptz
language sql stable set search_path = public
as $$
  select date_trunc(p_unit, now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
$$;
revoke execute on function public.ist_period_start(text) from public, anon, authenticated;

-- ---- hosts (who receives the most)
create or replace function public.rankings_daily()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= public.ist_period_start('day')
  group by receiver_id
  order by score desc;
$$;

create or replace function public.rankings_weekly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= public.ist_period_start('week')
  group by receiver_id
  order by score desc;
$$;

create or replace function public.rankings_monthly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select receiver_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= public.ist_period_start('month')
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
  where created_at >= public.ist_period_start('day')
  group by sender_id
  order by score desc;
$$;

create or replace function public.rankings_top_gifters_weekly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= public.ist_period_start('week')
  group by sender_id
  order by score desc;
$$;

create or replace function public.rankings_top_gifters_monthly()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  where created_at >= public.ist_period_start('month')
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
  where gt.created_at >= public.ist_period_start('day')
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
  where gt.created_at >= public.ist_period_start('week')
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
  where gt.created_at >= public.ist_period_start('month')
  group by a.id, a.name
  order by score desc;
$$;
