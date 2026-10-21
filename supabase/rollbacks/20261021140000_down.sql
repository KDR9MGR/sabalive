-- Down script for supabase/migrations/20261021140000_salary_month_summary.sql
-- Applied BY HAND only. Removes the read-only summary function; nothing else depends on it but the panel's "By month" table.
begin;
set local lock_timeout = '5s';
drop function if exists public.salary_month_summary(integer, uuid);
commit;
