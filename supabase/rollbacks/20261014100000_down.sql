-- Down script for supabase/migrations/20261014100000_lucky_box_history.sql
-- Applied BY HAND only. The function only reads, so nothing else depends on it besides the panel's Lucky Box page.
begin;
set local lock_timeout = '5s';
drop function if exists public.lucky_box_history(integer);
commit;
