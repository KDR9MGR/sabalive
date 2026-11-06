-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/pull_back_coin_transfers_rollback_test.sql
-- Proves the down script of 20261106140000: the two functions and the two columns are gone, and Access Control is back to the old key list.
\i supabase/rollbacks/20261106140000_down.sql
select 'functions gone (expect 0)' as check, count(*) as n from pg_proc where proname in ('pull_back_coin_transfer', 'staff_can_pull_back_coins');
select 'columns gone (expect 0)' as check, count(*) as n from information_schema.columns where table_name = 'coin_transfers' and column_name in ('pulled_back_at', 'pulled_back_by');
insert into auth.users (id, email) values ('d1000000-0000-0000-0000-000000000001', 'super@x'), ('d2000000-0000-0000-0000-000000000002', 'cty@x');
insert into public.staff_roles (user_id, role) values ('d1000000-0000-0000-0000-000000000001', 'super_admin'), ('d2000000-0000-0000-0000-000000000002', 'country_admin');
select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000001', false);
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
select 'the old key list is back: pull_back_coins is unknown again, manage_tags still works (expect t, t)' as check,
  pg_temp.refused('select public.set_staff_permissions(''d2000000-0000-0000-0000-000000000002'', ''{"pull_back_coins": true}''::jsonb)', 'Unknown permission%') as unknown_again,
  (select (public.set_staff_permissions('d2000000-0000-0000-0000-000000000002', '{"manage_tags": true}'::jsonb) ->> 'manage_tags')::boolean) as still_works;
