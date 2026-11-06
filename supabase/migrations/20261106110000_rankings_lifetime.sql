-- Lifetime boards in the app's Rankings (owner, 2026-11-06: "in ranking add lifetime tab next to monthly and show records from day 0").
--
-- The three boards keep the rules of 20261101120000 (Hosts = diamonds received through gifts, Gifters = coins spent on gifts, Agencies = the diamonds of all the agency's
-- hosts added together), but over EVERY gift ever sent: there is no start date and nothing ever resets.
--   hosts:    rankings_all_time()  (already in the database since 20260905090600 and unchanged: the same sum, no date filter; the app only had no tab for it)
--   gifters:  rankings_top_gifters_lifetime()   NEW
--   agencies: rankings_agencies_lifetime()      NEW
-- Additive: two new functions (new names), nothing renamed or changed, so every installed app keeps working and an app that does not know the tab simply never calls them.
-- Same shape as the daily / weekly / monthly functions (profile_id + score, agency_id + agency_name + score), best first, at most 200 rows (the app shows 100).
-- Cost note: a lifetime board adds up the whole gift_transactions table on every call (the monthly ones only read since the 1st), so it grows with the history. It is one
-- indexed-free group-by today; if the table ever gets big (hundreds of thousands of rows) replace the body with a small table refreshed by pg_cron, the same way
-- game_popularity is (the function name, columns and the app stay as they are).
-- Rollback: supabase/rollbacks/20261106110000_down.sql.
set local lock_timeout = '5s';

-- ---- gifters (who spent the most, ever)
create or replace function public.rankings_top_gifters_lifetime()
returns table (profile_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  select sender_id, sum(coins)::bigint as score
  from public.gift_transactions
  group by sender_id
  order by score desc
  limit 200;
$$;

-- ---- agencies (all of an agency's hosts together, ever; the agency a host belongs to NOW, as in the other agency boards)
create or replace function public.rankings_agencies_lifetime()
returns table (agency_id uuid, agency_name text, score bigint)
language sql stable security definer set search_path = public
as $$
  select a.id, a.name, sum(gt.coins)::bigint as score
  from public.gift_transactions gt
  join public.host_profiles hp on hp.profile_id = gt.receiver_id
  join public.agencies a on a.id = hp.agency_id
  group by a.id, a.name
  order by score desc
  limit 200;
$$;

-- readable by signed-in app users (the Rankings screen is behind login); not by anon
revoke execute on function public.rankings_top_gifters_lifetime() from public, anon;
revoke execute on function public.rankings_agencies_lifetime() from public, anon;
grant execute on function public.rankings_top_gifters_lifetime() to authenticated;
grant execute on function public.rankings_agencies_lifetime() to authenticated;
