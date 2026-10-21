-- Down script for supabase/migrations/20261021100000_lucky_box_pull_back_extras.sql
-- Applied BY HAND only. Removes the two functions. Cannot be undone by this script: boxes already pulled back (their
-- 'grant_reversal' and audit-log rows stay; pay one back with a normal grant if it was a mistake).
begin;
set local lock_timeout = '5s';
drop function if exists public.lucky_box_pull_back_extras(date, date, text);
drop function if exists public.lucky_box_extra_wins(date, date, text);
commit;
