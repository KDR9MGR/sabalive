-- Down script for supabase/migrations/20261101120000_rankings_reset_0010.sql
-- Applied BY HAND only. Puts the leaderboards back on a 00:00 India time reset (the state of 20261101020000) and removes the panel's reader and the window helper.
-- The rankings store nothing, so there is nothing else to undo.
begin;
set local lock_timeout = '5s';

-- the helper as 20261101020000 defined it: the India day / week / month start at midnight
create or replace function public.ist_period_start(p_unit text)
returns timestamptz
language sql stable set search_path = public
as $$
  select date_trunc(p_unit, now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
$$;
revoke execute on function public.ist_period_start(text) from public, anon, authenticated;

drop function if exists public.admin_leaderboard(text, text, text, integer);
drop function if exists public.ist_period_bounds(text, integer);
commit;
