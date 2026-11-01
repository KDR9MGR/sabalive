-- Leaderboards reset at 00:10 India time (not 00:00), and the panel gets its own leaderboard reader.
--
-- THE RULES (owner, 2026-11-01)
--   Hosts      the DIAMONDS they received through gifts (1 coin gifted = 1 diamond received, the same amount the wallet is credited).
--   Gifters    the COINS they spent on gifts.
--   Agencies   the DIAMONDS received by all the hosts under the agency, added together.
--   Daily boards reset every day, weekly boards every Monday, monthly boards on the 1st of each month, all at 00:10 India time (IST).
-- The three scores already follow those rules (gift_transactions.coins is both what the sender paid and what the receiver was credited, see send_gift_v2); only
-- the reset moment changes here.
--
-- WHAT THIS DOES
-- 1. ist_period_start('day' | 'week' | 'month') now returns the 00:10 IST moment instead of 00:00 IST. The nine ranking functions of 20261101020000 already read it,
--    so all nine (hosts, gifters, agencies x daily, weekly, monthly) move to 00:10 for every installed app version the moment this is applied; their names, columns
--    and arguments do not change, and nothing is stored, so there is nothing to recompute. Between 00:00 and 00:10 the boards still show the period that is ending;
--    a gift sent in those ten minutes belongs to that period. A gift at exactly 00:10:00 belongs to the new one.
-- 2. ist_period_bounds(unit, back) returns the start and end of the current (back = 0) or the previous (back = 1) period, for the panel.
-- 3. admin_leaderboard(board, period, which, limit) is the panel's reader (Master and Super Admin only): the same sums as the app's boards over the same windows, with
--    the person's app User ID, name and agency, the window shown on the page, the number of entries and the total. It can also read the PREVIOUS day / week / month,
--    which the app cannot (once a board resets, the app has no way back to it).
-- Additive: one replaced one-line helper and two new functions. Rollback: supabase/rollbacks/20261101120000_down.sql (back to 00:00 India time).
set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------------- 1
-- The start of the current India day / week (Monday) / month, as an exact moment: the 00:10 IST after midnight. Looking ten minutes back first is what keeps the old
-- period alive until 00:10.
create or replace function public.ist_period_start(p_unit text)
returns timestamptz
language sql stable set search_path = public
as $$
  select (date_trunc(p_unit, (now() - interval '10 minutes') at time zone 'Asia/Kolkata') + interval '10 minutes') at time zone 'Asia/Kolkata';
$$;
revoke execute on function public.ist_period_start(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------- 2
-- The window of the current period (p_back = 0) or the one before it (p_back = 1, 2, ...). The arithmetic is done on the India wall clock, never on the timestamptz,
-- so "one month back" is always the 1st at 00:10 whatever the month's length.
create or replace function public.ist_period_bounds(p_unit text, p_back integer default 0)
returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable set search_path = public
as $$
declare
  v_step interval;
  v_local timestamp;
begin
  v_step := case p_unit when 'day' then interval '1 day' when 'week' then interval '1 week' when 'month' then interval '1 month' end;
  if v_step is null then
    raise exception 'Unknown period %', p_unit;
  end if;
  v_local := date_trunc(p_unit, (now() - interval '10 minutes') at time zone 'Asia/Kolkata') + interval '10 minutes' - greatest(coalesce(p_back, 0), 0) * v_step;
  starts_at := v_local at time zone 'Asia/Kolkata';
  ends_at := (v_local + v_step) at time zone 'Asia/Kolkata';
  return next;
end;
$$;
revoke execute on function public.ist_period_bounds(text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------- 3
-- One call for the panel's Leaderboards page. Returns
--   { board, period, which, starts_at, ends_at, entries, total, rows: [ { rank, id, user_id, name, username, avatar_url, agency | country, score, gifts, hosts }, ... ] }
-- rank 1 is the highest score; a tie goes to whoever reached the score first. entries and total cover everybody on the board, rows only the first p_limit (1 to 500).
-- hosts and gifters rows carry the person (id = profile id, user_id = the app User ID; hosts also their agency's name); agencies rows carry the agency (id = agency id,
-- user_id = its number, country, and hosts = how many of its hosts received a gift in the period).
create or replace function public.admin_leaderboard(
  p_board text,
  p_period text,
  p_which text default 'current',
  p_limit integer default 100)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_rows jsonb;
  v_entries bigint;
  v_total bigint;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only a Master or a Super Admin can open the leaderboards';
  end if;
  if p_board is null or p_board not in ('hosts', 'gifters', 'agencies') then
    raise exception 'Unknown board %', p_board;
  end if;
  if p_period is null or p_period not in ('day', 'week', 'month') then
    raise exception 'Unknown period %', p_period;
  end if;
  if p_which is null or p_which not in ('current', 'previous') then
    raise exception 'Unknown choice %', p_which;
  end if;

  select b.starts_at, b.ends_at into v_from, v_to
    from public.ist_period_bounds(p_period, case when p_which = 'previous' then 1 else 0 end) b;

  if p_board = 'agencies' then
    with agg as (
      select hp.agency_id as id, sum(gt.coins)::bigint as score, count(*)::bigint as gifts,
             count(distinct gt.receiver_id)::bigint as hosts, max(gt.created_at) as last_at
        from public.gift_transactions gt
        join public.host_profiles hp on hp.profile_id = gt.receiver_id
        join public.agencies a on a.id = hp.agency_id
       where gt.created_at >= v_from and gt.created_at < v_to
       group by hp.agency_id
    ), ranked as (
      select g.*, row_number() over (order by g.score desc, g.last_at, g.id) as rank from agg g
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank', r.rank, 'id', r.id, 'user_id', a.display_id, 'name', a.name, 'country', a.country,
             'score', r.score, 'gifts', r.gifts, 'hosts', r.hosts) order by r.rank) filter (where r.rank <= v_limit), '[]'::jsonb),
           count(*), coalesce(sum(r.score), 0)::bigint
      into v_rows, v_entries, v_total
      from ranked r join public.agencies a on a.id = r.id;

  elsif p_board = 'hosts' then
    with agg as (
      select gt.receiver_id as id, sum(gt.coins)::bigint as score, count(*)::bigint as gifts, max(gt.created_at) as last_at
        from public.gift_transactions gt
        join public.profiles p on p.id = gt.receiver_id and not coalesce(p.is_ghost, false)
       where gt.created_at >= v_from and gt.created_at < v_to
       group by gt.receiver_id
    ), ranked as (
      select g.*, row_number() over (order by g.score desc, g.last_at, g.id) as rank from agg g
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank', r.rank, 'id', r.id, 'user_id', p.display_id, 'name', p.name, 'username', p.username, 'avatar_url', p.avatar_url,
             'agency', ag.name, 'score', r.score, 'gifts', r.gifts) order by r.rank) filter (where r.rank <= v_limit), '[]'::jsonb),
           count(*), coalesce(sum(r.score), 0)::bigint
      into v_rows, v_entries, v_total
      from ranked r
      join public.profiles p on p.id = r.id
      left join public.host_profiles hp on hp.profile_id = r.id
      left join public.agencies ag on ag.id = hp.agency_id;

  else
    with agg as (
      select gt.sender_id as id, sum(gt.coins)::bigint as score, count(*)::bigint as gifts, max(gt.created_at) as last_at
        from public.gift_transactions gt
        join public.profiles p on p.id = gt.sender_id and not coalesce(p.is_ghost, false)
       where gt.created_at >= v_from and gt.created_at < v_to
       group by gt.sender_id
    ), ranked as (
      select g.*, row_number() over (order by g.score desc, g.last_at, g.id) as rank from agg g
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank', r.rank, 'id', r.id, 'user_id', p.display_id, 'name', p.name, 'username', p.username, 'avatar_url', p.avatar_url,
             'score', r.score, 'gifts', r.gifts) order by r.rank) filter (where r.rank <= v_limit), '[]'::jsonb),
           count(*), coalesce(sum(r.score), 0)::bigint
      into v_rows, v_entries, v_total
      from ranked r join public.profiles p on p.id = r.id;
  end if;

  return jsonb_build_object(
    'board', p_board, 'period', p_period, 'which', p_which,
    'starts_at', v_from, 'ends_at', v_to,
    'entries', v_entries, 'total', v_total, 'rows', v_rows);
end;
$$;
revoke execute on function public.admin_leaderboard(text, text, text, integer) from public, anon;
grant execute on function public.admin_leaderboard(text, text, text, integer) to authenticated;
