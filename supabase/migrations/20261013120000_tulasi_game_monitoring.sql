-- Tulasi games, part 3: monitoring. Because game coins are normal coins (owner's decision), the risk is a route
-- "win in a game -> gift a friendly host -> host withdraws". These two views let staff see it:
--   game_winner_gifting  people who won in games on a day and gifted coins that day or the day after
--   game_host_inflow     per host per day: coins received as gifts, and how much of it came from people who were net
--                        winners in games that day
-- security_invoker: a caller sees only what their own access to game_transactions / gift_transactions allows (staff). Nothing
-- existing changes. Rollback: supabase/rollbacks/20261013120000_tulasi_game_monitoring_down.sql.
create or replace view public.game_winner_gifting with (security_invoker = true) as
select t.profile_id, t.day, t.net as game_net, g.gifted, g.receivers
  from public.game_player_day_totals t
  cross join lateral (
    select coalesce(sum(x.coins), 0)::bigint as gifted, count(distinct x.receiver_id) as receivers
      from public.gift_transactions x
     where x.sender_id = t.profile_id
       and (x.created_at at time zone 'UTC')::date between t.day and t.day + 1
  ) g
 where t.net > 0 and g.gifted > 0;

create or replace view public.game_host_inflow with (security_invoker = true) as
select x.receiver_id as host_id,
       (x.created_at at time zone 'UTC')::date as day,
       sum(x.coins)::bigint as received,
       coalesce(sum(x.coins) filter (where w.profile_id is not null), 0)::bigint as from_game_winners,
       count(distinct x.sender_id) filter (where w.profile_id is not null) as winner_senders
  from public.gift_transactions x
  left join (select profile_id, day from public.game_player_day_totals where net > 0) w
    on w.profile_id = x.sender_id and w.day = (x.created_at at time zone 'UTC')::date
 group by 1, 2;
