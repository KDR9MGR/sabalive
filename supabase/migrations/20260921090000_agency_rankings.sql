-- Agency leaderboard: sum of gift coins received by all of an agency's
-- hosts, mirroring the existing per-host rankings_daily/weekly/monthly
-- (same date_trunc windows, same gift_transactions source) but grouped up
-- through host_profiles.agency_id instead of by individual receiver.
create function public.rankings_agencies_daily()
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

create function public.rankings_agencies_weekly()
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

create function public.rankings_agencies_monthly()
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
