-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/pull_back_coin_transfers_test.sql
-- Proves (20261106140000): the permission (Super always, Master unless blocked, others only when granted); a reason is required; a Master / Super may pull
-- back any transfer, everyone else only one they sent; the coins go from the recipient back to the sender in two tied ledger rows; all or nothing
-- (refused when the recipient spent below it); once only; one audit row; a normal user and a signed-out caller are refused.
insert into auth.users (id, email) values
  ('b1000000-0000-0000-0000-000000000001', 'master@x'),
  ('b2000000-0000-0000-0000-000000000002', 'global@x'),
  ('b3000000-0000-0000-0000-000000000003', 'country@x'),
  ('b4000000-0000-0000-0000-000000000004', 'plain@x'),
  ('b5000000-0000-0000-0000-000000000005', 'global2@x'),
  ('b6000000-0000-0000-0000-000000000006', 'blocked_master@x'),
  ('b7000000-0000-0000-0000-000000000007', 'super@x');
insert into public.staff_roles (user_id, role) values
  ('b1000000-0000-0000-0000-000000000001', 'admin'),
  ('b2000000-0000-0000-0000-000000000002', 'global_admin'),
  ('b3000000-0000-0000-0000-000000000003', 'country_admin'),
  ('b5000000-0000-0000-0000-000000000005', 'global_admin'),
  ('b6000000-0000-0000-0000-000000000006', 'admin'),
  ('b7000000-0000-0000-0000-000000000007', 'super_admin');
update public.staff_roles set permissions = '{"pull_back_coins": false}'::jsonb where user_id = 'b6000000-0000-0000-0000-000000000006';
insert into public.wallet_ledger (profile_id, kind, currency, amount, note) values
  ('b1000000-0000-0000-0000-000000000001', 'grant', 'coins', 10000, 'test funds'),
  ('b2000000-0000-0000-0000-000000000002', 'grant', 'coins', 10000, 'test funds');
-- two real-looking transfers: Master -> Global (1000), Global -> Country (400), and Global -> Country (300) that the country admin then spends
insert into public.coin_transfers (id, sender_id, recipient_id, coins, note, recipient_kind) values
  ('c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002', 1000, 'm to g', 'global_admin'),
  ('c2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', 'b3000000-0000-0000-0000-000000000003', 400, 'g to c', 'country_admin'),
  ('c3000000-0000-0000-0000-000000000003', 'b2000000-0000-0000-0000-000000000002', 'b3000000-0000-0000-0000-000000000003', 300, 'g to c 2', 'country_admin');
-- the money of those transfers (the same ledger rows transfer_coins_down writes): country holds 700, global holds 10000 - 700 + 1000
insert into public.wallet_ledger (profile_id, kind, currency, amount, note) values
  ('b2000000-0000-0000-0000-000000000002', 'transfer_in', 'coins', 1000, 'm to g'),
  ('b1000000-0000-0000-0000-000000000001', 'transfer_out', 'coins', -1000, 'm to g'),
  ('b3000000-0000-0000-0000-000000000003', 'transfer_in', 'coins', 700, 'g to c'),
  ('b2000000-0000-0000-0000-000000000002', 'transfer_out', 'coins', -700, 'g to c');

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlerrm like p_expect;
end $$;

select '0 start: master 9000, global 10300, country 700 (expect 9000, 10300, 700)' as check,
  (select coins from public.wallets where profile_id = 'b1000000-0000-0000-0000-000000000001') as master,
  (select coins from public.wallets where profile_id = 'b2000000-0000-0000-0000-000000000002') as global,
  (select coins from public.wallets where profile_id = 'b3000000-0000-0000-0000-000000000003') as country;

-- 1. who may
select set_config('request.jwt.claim.sub', '', false);
select '1 signed out is refused (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c2000000-0000-0000-0000-000000000002'', ''abuse'')', 'You do not have permission%') as ok;
select set_config('request.jwt.claim.sub', 'b4000000-0000-0000-0000-000000000004', false);
select '1b a normal user is refused (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c2000000-0000-0000-0000-000000000002'', ''abuse'')', 'You do not have permission%') as ok;
select set_config('request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000002', false);
select '1c a Global Admin WITHOUT the permission is refused (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c2000000-0000-0000-0000-000000000002'', ''test'')', 'You do not have permission%') as ok;
select set_config('request.jwt.claim.sub', 'b6000000-0000-0000-0000-000000000006', false);
select '1d a Master with it switched off is refused (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c2000000-0000-0000-0000-000000000002'', ''test'')', 'You do not have permission%') as ok;

-- 2. grant it to the Global Admin and to another Global Admin: scope = their own transfers
update public.staff_roles set permissions = '{"pull_back_coins": true}'::jsonb where user_id in ('b2000000-0000-0000-0000-000000000002', 'b5000000-0000-0000-0000-000000000005');
select set_config('request.jwt.claim.sub', 'b5000000-0000-0000-0000-000000000005', false);
select '2 a granted Global Admin cannot touch ANOTHER chain (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c2000000-0000-0000-0000-000000000002'', ''test'')', 'You can only pull back transfers you sent%') as ok;
select set_config('request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000002', false);
select '2b a reason is required (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c2000000-0000-0000-0000-000000000002'', ''  '')', 'Give a reason%') as ok;
select '2c an unknown transfer is refused (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c9000000-0000-0000-0000-000000000009'', ''test'')', 'That transfer does not exist%') as ok;
select '2d the sender cannot pull back a transfer that was sent TO them (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c1000000-0000-0000-0000-000000000001'', ''test'')', 'You can only pull back transfers you sent%') as ok;

-- 3. the pull-back of a transfer the sender made
create temp table r as select public.pull_back_coin_transfer('c2000000-0000-0000-0000-000000000002', 'sent to the wrong person') as j;
select '3 the coins moved back (expect global 10700, country 300, taken 400)' as check,
  (select coins from public.wallets where profile_id = 'b2000000-0000-0000-0000-000000000002') as global,
  (select coins from public.wallets where profile_id = 'b3000000-0000-0000-0000-000000000003') as country,
  (select (j ->> 'coins')::int from r) as taken;
select '3b two ledger rows tied to the transfer: -400 grant_reversal and +400 transfer_in (expect 2, t, t)' as check,
  (select count(*) from public.wallet_ledger where reference_table = 'coin_transfers' and reference_id = 'c2000000-0000-0000-0000-000000000002') as rows,
  exists (select 1 from public.wallet_ledger where reference_id = 'c2000000-0000-0000-0000-000000000002' and kind = 'grant_reversal' and amount = -400 and profile_id = 'b3000000-0000-0000-0000-000000000003') as recipient_row,
  exists (select 1 from public.wallet_ledger where reference_id = 'c2000000-0000-0000-0000-000000000002' and kind = 'transfer_in' and amount = 400 and profile_id = 'b2000000-0000-0000-0000-000000000002') as sender_row;
select '3c the transfer is marked, one warning audit row (expect t, t, 1, warning)' as check,
  (select pulled_back_at is not null from public.coin_transfers where id = 'c2000000-0000-0000-0000-000000000002') as marked,
  (select pulled_back_by = 'b2000000-0000-0000-0000-000000000002' from public.coin_transfers where id = 'c2000000-0000-0000-0000-000000000002') as by_ok,
  (select count(*) from public.audit_logs where action = 'coin_transfer.pull_back') as audit,
  (select severity from public.audit_logs where action = 'coin_transfer.pull_back') as severity;
select '3d once only (expect t)' as check, pg_temp.refused('select public.pull_back_coin_transfer(''c2000000-0000-0000-0000-000000000002'', ''again'')', 'This transfer has already been pulled back%') as ok;

-- 4. all or nothing: the country admin spends 250 of the remaining 300, then 300 cannot be pulled back
insert into public.wallet_ledger (profile_id, kind, currency, amount, note) values ('b3000000-0000-0000-0000-000000000003', 'withdrawal', 'coins', -250, 'spent');
select '4 not enough left is refused and nothing moves (expect t, country 50, transfer not marked)' as check,
  pg_temp.refused('select public.pull_back_coin_transfer(''c3000000-0000-0000-0000-000000000003'', ''test'')', 'Cannot pull back: the recipient has only 50 of the 300%') as ok,
  (select coins from public.wallets where profile_id = 'b3000000-0000-0000-0000-000000000003') as country,
  (select pulled_back_at is null from public.coin_transfers where id = 'c3000000-0000-0000-0000-000000000003') as not_marked;

-- 5. a Master and a Super Admin may pull back ANY transfer (the Master with the default)
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);
create temp table r5 as select public.pull_back_coin_transfer('c1000000-0000-0000-0000-000000000001', 'test') as j;
select '5 a Master pulls back someone else''s transfer: 1000 from global to master (expect t, master 10000, global 9700)' as check,
  (select (j ->> 'coins')::int = 1000 from r5) as done,
  (select coins from public.wallets where profile_id = 'b1000000-0000-0000-0000-000000000001') as master,
  (select coins from public.wallets where profile_id = 'b2000000-0000-0000-0000-000000000002') as global;
select set_config('request.jwt.claim.sub', 'b7000000-0000-0000-0000-000000000007', false);
select '5b a Super Admin may too, and is refused by the balance rule here (expect t)' as check,
  pg_temp.refused('select public.pull_back_coin_transfer(''c3000000-0000-0000-0000-000000000003'', ''test'')', 'Cannot pull back: the recipient has only%') as ok;

-- 6. the total of coins is unchanged by all of this (a pull-back only moves coins): grants 20000 - 250 spent
select '6 coins are conserved (expect 19750)' as check, (select sum(coins) from public.wallets where profile_id::text like 'b_000000-%') as total;

-- 7. Access Control can save the permission, and a Master can only hand it on if they hold it themselves
select set_config('request.jwt.claim.sub', 'b7000000-0000-0000-0000-000000000007', false);
select '7 a Super Admin saves pull_back_coins on a Country Admin (expect t)' as check,
  (select (public.set_staff_permissions('b3000000-0000-0000-0000-000000000003', '{"pull_back_coins": true}'::jsonb) ->> 'pull_back_coins')::boolean) as saved,
  (select (permissions ->> 'pull_back_coins')::boolean from public.staff_roles where user_id = 'b3000000-0000-0000-0000-000000000003') as stored;
select '7b an unknown permission is still refused (expect t)' as check, pg_temp.refused('select public.set_staff_permissions(''b3000000-0000-0000-0000-000000000003'', ''{"made_up": true}''::jsonb)', 'Unknown permission%') as ok;
insert into auth.users (id, email) values ('b8000000-0000-0000-0000-000000000008', 'sub@x');
insert into public.staff_roles (user_id, role) values ('b8000000-0000-0000-0000-000000000008', 'sub_admin');
select set_config('request.jwt.claim.sub', 'b6000000-0000-0000-0000-000000000006', false);
select '7c a Master whose own pull_back_coins is switched off cannot give it (expect t)' as check, pg_temp.refused('select public.set_staff_permissions(''b8000000-0000-0000-0000-000000000008'', ''{"pull_back_coins": true}''::jsonb)', 'You do not have "pull_back_coins" yourself%') as ok;
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);
select '7d a Master who holds it (default) can give it (expect t)' as check,
  (select (public.set_staff_permissions('b8000000-0000-0000-0000-000000000008', '{"pull_back_coins": true}'::jsonb) ->> 'pull_back_coins')::boolean) as saved;
