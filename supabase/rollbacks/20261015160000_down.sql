-- Down script for supabase/migrations/20261015160000_admin_pull_back_all_coins.sql
-- Applied BY HAND only. Removes the function. Cannot be undone by this script: coins already pulled back (their
-- 'grant_reversal' ledger rows and audit-log rows stay; give the coins back with a normal grant if one was a mistake).
begin;
set local lock_timeout = '5s';
drop function if exists public.admin_pull_back_all_coins(uuid, text);
commit;
