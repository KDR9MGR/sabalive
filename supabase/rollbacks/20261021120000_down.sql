-- Down script for supabase/migrations/20261021120000_salary_slabs_monthly_report.sql
-- Applied BY HAND only. Removes the two functions and the slab table. Cannot be undone by this script: payslips already created by
-- "Assign Salary Reward" (they are normal salary_payments rows; delete or hold them from the Salary list if one was a mistake) and the audit rows.
begin;
set local lock_timeout = '5s';
drop function if exists public.salary_assign_rewards(text, uuid);
drop function if exists public.salary_report(text, uuid);
drop table if exists public.salary_slabs;
commit;
