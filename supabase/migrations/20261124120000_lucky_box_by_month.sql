-- Lucky Box rewards, month by month (India time), for the panel's Lucky Box page.
--
-- WHAT WAS WRONG. The page's "Reward history" read the 500 newest wins across ALL hosts (a plain table read, so also capped by the server's 1000-row limit), showed a date
-- but no time, and had no way to pick a month: an owner could not see "what did this host get in October, on which days and at what time". Anything older than the
-- newest 500 wins was simply not reachable.
--
-- WHAT THIS ADDS. Two read-only functions (new names; nothing existing is touched), both for the month 'YYYY-MM' cut in INDIA time (like Salary and the Lucky Box day):
--   lucky_box_month_people(month)        one row per person who won in the month: how many wins, diamonds won, diamonds pulled back, first and last win
--   lucky_box_month_rewards(month, user) every win of the month with its exact time (optionally of one person, by their app User ID), newest first, and whether it was pulled back
-- The source is the wallet ledger rows the payout job writes (note 'lucky_box'); a win counts as pulled back when a 'grant_reversal' row points at it (the same rule the Lucky
-- Box page and lucky_box_history use). Same gate as the rest of the page: a Master or Super Admin with Lucky Box access (staff_can('manage_lucky_box')).
-- Rollback: supabase/rollbacks/20261124120000_down.sql.
set local lock_timeout = '5s';

create or replace function public.lucky_box_month_people(p_month text)
returns table (
  profile_id uuid,
  name text,
  username text,
  display_id bigint,
  wins integer,
  diamonds bigint,
  pulled_back_diamonds bigint,
  first_win timestamptz,
  last_win timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
#variable_conflict use_column
declare
  v_from timestamptz;
  v_to timestamptz;
begin
  if not public.staff_can('manage_lucky_box') then
    raise exception 'Only a Master or Super Admin with Lucky Box access can see this';
  end if;
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Pick a month as YYYY-MM';
  end if;
  v_from := (p_month || '-01')::date::timestamp at time zone 'Asia/Kolkata';
  v_to := ((p_month || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata';

  return query
  with wins as materialized (
    select w.id, w.profile_id, w.amount, w.created_at
      from public.wallet_ledger w
     where w.note = 'lucky_box' and w.created_at >= v_from and w.created_at < v_to
  ), rev as materialized (
    select x.reference_id
      from public.wallet_ledger x
     where x.kind = 'grant_reversal' and x.reference_table = 'wallet_ledger'
       and x.reference_id in (select id from wins)
  )
  select p.id, p.name, p.username, p.display_id,
         count(*)::int,
         sum(w.amount)::bigint,
         coalesce(sum(w.amount) filter (where w.id in (select reference_id from rev)), 0)::bigint,
         min(w.created_at),
         max(w.created_at)
    from wins w
    join public.profiles p on p.id = w.profile_id
   where not coalesce(p.is_ghost, false)
   group by p.id, p.name, p.username, p.display_id
   order by sum(w.amount) desc, p.display_id;
end;
$$;
revoke execute on function public.lucky_box_month_people(text) from public, anon;
grant execute on function public.lucky_box_month_people(text) to authenticated;

create or replace function public.lucky_box_month_rewards(p_month text, p_user bigint default null)
returns table (
  reward_id uuid,
  profile_id uuid,
  name text,
  username text,
  display_id bigint,
  diamonds bigint,
  won_at timestamptz,
  stream_id uuid,
  pulled_back boolean
)
language plpgsql stable security definer set search_path = public
as $$
#variable_conflict use_column
declare
  v_from timestamptz;
  v_to timestamptz;
begin
  if not public.staff_can('manage_lucky_box') then
    raise exception 'Only a Master or Super Admin with Lucky Box access can see this';
  end if;
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Pick a month as YYYY-MM';
  end if;
  v_from := (p_month || '-01')::date::timestamp at time zone 'Asia/Kolkata';
  v_to := ((p_month || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata';

  return query
  with wins as materialized (
    select w.id, w.profile_id, w.amount, w.reference_id, w.created_at
      from public.wallet_ledger w
     where w.note = 'lucky_box' and w.created_at >= v_from and w.created_at < v_to
  ), rev as materialized (
    select x.reference_id
      from public.wallet_ledger x
     where x.kind = 'grant_reversal' and x.reference_table = 'wallet_ledger'
       and x.reference_id in (select id from wins)
  )
  select w.id, p.id, p.name, p.username, p.display_id,
         w.amount::bigint, w.created_at, w.reference_id,
         (w.id in (select reference_id from rev))
    from wins w
    join public.profiles p on p.id = w.profile_id
   where not coalesce(p.is_ghost, false)
     and (p_user is null or p.display_id = p_user)
   order by w.created_at desc, w.id;
end;
$$;
revoke execute on function public.lucky_box_month_rewards(text, bigint) from public, anon;
grant execute on function public.lucky_box_month_rewards(text, bigint) to authenticated;
