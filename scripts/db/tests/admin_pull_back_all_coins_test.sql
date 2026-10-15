-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/admin_pull_back_all_coins_test.sql
-- Proves (20261015160000): a Master / Super Admin takes the WHOLE coin balance in one ledger row and the diamonds stay; a reason is required;
-- not your own account, not a ghost, a staff account only by a Super Admin; an empty wallet is refused; a Master with the coins switch off,
-- a normal user and a signed-out caller are refused; one critical audit-log row per pull-back.
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'master@x'),
  ('a2000000-0000-0000-0000-000000000002', 'super@x'),
  ('a3000000-0000-0000-0000-000000000003', 'target@x'),
  ('a4000000-0000-0000-0000-000000000004', 'empty@x'),
  ('a5000000-0000-0000-0000-000000000005', 'ghost@x'),
  ('a6000000-0000-0000-0000-000000000006', 'staff2@x'),
  ('a7000000-0000-0000-0000-000000000007', 'nocoins@x'),
  ('a8000000-0000-0000-0000-000000000008', 'plain@x');
update public.profiles set is_ghost = true where id = 'a5000000-0000-0000-0000-000000000005';
insert into public.staff_roles (user_id, role) values
  ('a1000000-0000-0000-0000-000000000001', 'admin'),
  ('a2000000-0000-0000-0000-000000000002', 'super_admin'),
  ('a6000000-0000-0000-0000-000000000006', 'admin'),
  ('a7000000-0000-0000-0000-000000000007', 'admin');
update public.staff_roles set permissions = '{"manage_coins": false}'::jsonb where user_id = 'a7000000-0000-0000-0000-000000000007';
insert into public.wallet_ledger (profile_id, kind, currency, amount, note) values
  ('a3000000-0000-0000-0000-000000000003', 'grant', 'coins', 123456, 'test funds'),
  ('a3000000-0000-0000-0000-000000000003', 'grant', 'diamonds', 777, 'test diamonds'),
  ('a6000000-0000-0000-0000-000000000006', 'grant', 'coins', 50, 'test funds'),
  ('a5000000-0000-0000-0000-000000000005', 'grant', 'coins', 50, 'test funds');

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlerrm like p_expect;
end $$;

-- 1. who may do it
select set_config('request.jwt.claim.sub', '', false);
select '1 signed out is refused (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a3000000-0000-0000-0000-000000000003'', ''abuse'')', 'Only a Master%') as ok;
select set_config('request.jwt.claim.sub', 'a8000000-0000-0000-0000-000000000008', false);
select '1b a normal user is refused (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a3000000-0000-0000-0000-000000000003'', ''abuse'')', 'Only a Master%') as ok;
select set_config('request.jwt.claim.sub', 'a7000000-0000-0000-0000-000000000007', false);
select '1c a Master with the coins switch off is refused (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a3000000-0000-0000-0000-000000000003'', ''abuse'')', 'Only a Master%') as ok;

-- 2. refusals for a Master
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);
select '2 a reason is required (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a3000000-0000-0000-0000-000000000003'', ''  '')', 'Give a reason%') as ok;
select '2b not your own account (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a1000000-0000-0000-0000-000000000001'', ''test'')', 'You cannot pull coins back from your own%') as ok;
select '2c a ghost is refused (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a5000000-0000-0000-0000-000000000005'', ''test'')', 'That user does not exist%') as ok;
select '2d a staff account is refused for a Master (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a6000000-0000-0000-0000-000000000006'', ''test'')', 'Only a Super Admin can pull coins back from a staff%') as ok;
select '2e an empty wallet is refused (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a4000000-0000-0000-0000-000000000004'', ''test'')', 'This user has no coins to pull back%') as ok;
select '2f nothing changed so far (expect 123456, 777, 0 audit rows)' as check,
       (select coins from public.wallets where profile_id = 'a3000000-0000-0000-0000-000000000003') as coins,
       (select diamonds from public.wallets where profile_id = 'a3000000-0000-0000-0000-000000000003') as diamonds,
       (select count(*) from public.audit_logs where action = 'coins.pull_back_all') as audit;

-- 3. the pull-back
create temp table r as select public.admin_pull_back_all_coins('a3000000-0000-0000-0000-000000000003', 'bought with a stolen card') as j;
select '3 the whole balance is taken, diamonds stay (expect 123456, coins 0, diamonds 777)' as check,
       (j ->> 'coins')::bigint as taken,
       (select coins from public.wallets where profile_id = 'a3000000-0000-0000-0000-000000000003') as coins_left,
       (select diamonds from public.wallets where profile_id = 'a3000000-0000-0000-0000-000000000003') as diamonds_left
  from r;
select '3b one reversal row with the reason, one critical audit row (expect 1, t, 1, critical)' as check,
       (select count(*) from public.wallet_ledger where kind = 'grant_reversal' and profile_id = 'a3000000-0000-0000-0000-000000000003') as ledger_rows,
       (select note like 'Pulled back by admin: bought with a stolen card' from public.wallet_ledger where kind = 'grant_reversal' and profile_id = 'a3000000-0000-0000-0000-000000000003') as note_ok,
       (select count(*) from public.audit_logs where action = 'coins.pull_back_all') as audit,
       (select severity from public.audit_logs where action = 'coins.pull_back_all') as severity;
select '3c a second press finds nothing left (expect t)' as check, pg_temp.refused('select public.admin_pull_back_all_coins(''a3000000-0000-0000-0000-000000000003'', ''again'')', 'This user has no coins to pull back%') as ok;

-- 4. a Super Admin may take from a staff account
select set_config('request.jwt.claim.sub', 'a2000000-0000-0000-0000-000000000002', false);
select '4 a Super Admin may pull back from a staff account (expect 50)' as check, (public.admin_pull_back_all_coins('a6000000-0000-0000-0000-000000000006', 'test') ->> 'coins')::bigint as taken;
select set_config('request.jwt.claim.sub', '', false);

-- 5. the grants
select '5 anon cannot run it, signed-in users can (expect f, t)' as check,
       has_function_privilege('anon', 'public.admin_pull_back_all_coins(uuid,text)', 'execute') as anon,
       has_function_privilege('authenticated', 'public.admin_pull_back_all_coins(uuid,text)', 'execute') as authed;
