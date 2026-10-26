-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/diamond_reset_test.sql
-- Proves (20261026120000): only a Master / Super Admin passes (a Global Admin, a plain user and anon do not); a month must have ended and be confirmed by typing it;
-- the preview and the run take exactly the same amounts; a wallet never goes below 0 and never loses diamonds that arrived after the month (withdrawals are
-- assumed to use the oldest diamonds first); a pulled-back Lucky Box win is not a reward; ghosts are skipped; each (month, source) runs once; "both" is gift + reward;
-- the ledger rows are 'grant_reversal' tied to the run and do not change the Salary figures; undo gives the diamonds back and frees the month.
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-0000000000a1', 'master@x'),
  ('e1000000-0000-0000-0000-0000000000e6', 'super@x'),
  ('f1000000-0000-0000-0000-0000000000f7', 'global@x'),
  ('c1000000-0000-0000-0000-0000000000c1', 'plain@x'),
  ('b1000000-0000-0000-0000-0000000000b1', 'h1@x'),
  ('b2000000-0000-0000-0000-0000000000b2', 'h2@x'),
  ('b3000000-0000-0000-0000-0000000000b3', 'h3@x'),
  ('b4000000-0000-0000-0000-0000000000b4', 'h4@x'),
  ('b5000000-0000-0000-0000-0000000000b5', 'h5@x'),
  ('d1000000-0000-0000-0000-0000000000d5', 'ghost@x');
insert into public.staff_roles (user_id, role) values
  ('a1000000-0000-0000-0000-0000000000a1', 'admin'),
  ('e1000000-0000-0000-0000-0000000000e6', 'super_admin'),
  ('f1000000-0000-0000-0000-0000000000f7', 'global_admin');
set session_replication_role = replica;
update public.profiles set is_ghost = true where id = 'd1000000-0000-0000-0000-0000000000d5';
set session_replication_role = origin;

-- history. September 2026 (India time) is the month under test; the Oct rows are "after", the Aug row is "before".
-- h1: Aug gift 700 | Sep gift 600 + 400, Lucky Box 500, Lucky Box 300 pulled back                 -> balance 2200
-- h2: Sep gift 1000, withdrew 600 in Sep                                                          -> balance 400
-- h3: Sep gift 1000, Oct gift 300                                                                 -> balance 1300
-- h4: Sep gift 1000, Oct gift 300, Oct withdrawal 500                                             -> balance 800
-- ghost: Sep gift 200
insert into public.wallet_ledger (id, profile_id, kind, currency, amount, reference_table, note, created_at) values
  (gen_random_uuid(), 'b1000000-0000-0000-0000-0000000000b1', 'gift_received', 'diamonds', 700, null, null, '2026-08-10 12:00+00'),
  (gen_random_uuid(), 'b1000000-0000-0000-0000-0000000000b1', 'gift_received', 'diamonds', 600, null, null, '2026-09-10 12:00+00'),
  (gen_random_uuid(), 'b1000000-0000-0000-0000-0000000000b1', 'gift_received', 'diamonds', 400, null, null, '2026-09-11 12:00+00'),
  (gen_random_uuid(), 'b1000000-0000-0000-0000-0000000000b1', 'grant', 'diamonds', 500, null, 'lucky_box', '2026-09-12 12:00+00'),
  ('99999999-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000000b1', 'grant', 'diamonds', 300, null, 'lucky_box', '2026-09-13 12:00+00'),
  (gen_random_uuid(), 'b2000000-0000-0000-0000-0000000000b2', 'gift_received', 'diamonds', 1000, null, null, '2026-09-10 12:00+00'),
  (gen_random_uuid(), 'b3000000-0000-0000-0000-0000000000b3', 'gift_received', 'diamonds', 1000, null, null, '2026-09-10 12:00+00'),
  (gen_random_uuid(), 'b4000000-0000-0000-0000-0000000000b4', 'gift_received', 'diamonds', 1000, null, null, '2026-09-10 12:00+00');
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at) values
  ('b1000000-0000-0000-0000-0000000000b1', 'grant_reversal', 'diamonds', -300, 'wallet_ledger', '99999999-0000-0000-0000-000000000001', 'pulled back', '2026-09-14 12:00+00'),
  ('b2000000-0000-0000-0000-0000000000b2', 'withdrawal', 'diamonds', -600, 'withdrawals', null, 'paid', '2026-09-20 12:00+00'),
  ('b3000000-0000-0000-0000-0000000000b3', 'gift_received', 'diamonds', 300, null, null, null, '2026-10-05 12:00+00'),
  ('b4000000-0000-0000-0000-0000000000b4', 'gift_received', 'diamonds', 300, null, null, null, '2026-10-05 12:00+00'),
  ('b4000000-0000-0000-0000-0000000000b4', 'withdrawal', 'diamonds', -500, 'withdrawals', null, 'paid', '2026-10-06 12:00+00');
set session_replication_role = replica;
insert into public.wallet_ledger (profile_id, kind, currency, amount, created_at) values ('d1000000-0000-0000-0000-0000000000d5', 'gift_received', 'diamonds', 200, '2026-09-10 12:00+00');
update public.wallets set diamonds = 200 where profile_id = 'd1000000-0000-0000-0000-0000000000d5';
set session_replication_role = origin;
-- h5: July 2026, for the "both" button on its own month
insert into public.wallet_ledger (profile_id, kind, currency, amount, note, created_at) values
  ('b5000000-0000-0000-0000-0000000000b5', 'gift_received', 'diamonds', 300, null, '2026-07-10 12:00+00'),
  ('b5000000-0000-0000-0000-0000000000b5', 'grant', 'diamonds', 200, 'lucky_box', '2026-07-11 12:00+00');

create or replace function pg_temp.as_user(p_id text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_id, false); $$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
create or replace function pg_temp.dia(p_id text) returns bigint language sql as $$ select diamonds from public.wallets where profile_id = p_id::uuid; $$;

select '0 the setup balances (expect 2200, 400, 1300, 800, 200)' as check,
  pg_temp.dia('b1000000-0000-0000-0000-0000000000b1') as h1, pg_temp.dia('b2000000-0000-0000-0000-0000000000b2') as h2,
  pg_temp.dia('b3000000-0000-0000-0000-0000000000b3') as h3, pg_temp.dia('b4000000-0000-0000-0000-0000000000b4') as h4,
  pg_temp.dia('d1000000-0000-0000-0000-0000000000d5') as ghost;

-- 1. who may press
select pg_temp.as_user('f1000000-0000-0000-0000-0000000000f7');
select '1 a Global Admin is refused (expect t, t, t)' as check,
  pg_temp.refused('select public.admin_diamond_reset_preview(''2026-09'')', '%Only a Master or Super Admin%') as preview,
  pg_temp.refused('select public.admin_reset_diamonds(''2026-09'', ''gift'', ''2026-09'')', '%Only a Master or Super Admin%') as reset,
  pg_temp.refused('select public.admin_undo_diamond_reset(gen_random_uuid(), ''2026-09'')', '%Only a Master or Super Admin%') as undo;
select pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
select '1b a plain user is refused (expect t)' as check, pg_temp.refused('select public.admin_reset_diamonds(''2026-09'', ''gift'', ''2026-09'')', '%Only a Master or Super Admin%') as ok;
select '1c anon cannot call anything; the internals are not callable by app users (expect all f)' as check,
  has_function_privilege('anon', 'public.admin_reset_diamonds(text,text,text)', 'execute') as a1,
  has_function_privilege('anon', 'public.admin_diamond_reset_preview(text)', 'execute') as a2,
  has_function_privilege('authenticated', 'public._diamond_reset_plan(text,text)', 'execute') as a3,
  has_function_privilege('authenticated', 'public._diamond_reset_actor_ok()', 'execute') as a4;

-- 2. the preview (Master)
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select '2 preview September: gift 4 wallets 2900, reward 1 wallet 500, ended (expect 4, 2900, 1, 500, t, f, f)' as check,
  (p -> 'gift' ->> 'wallets')::int as gw, (p -> 'gift' ->> 'diamonds')::bigint as gd, (p -> 'reward' ->> 'wallets')::int as rw, (p -> 'reward' ->> 'diamonds')::bigint as rd,
  (p ->> 'ended')::boolean as ended, (p -> 'gift' ->> 'done')::boolean as gdone, (p -> 'reward' ->> 'done')::boolean as rdone
  from (select public.admin_diamond_reset_preview('2026-09') as p) q;
select '2b the ghost and the pulled-back win are not in it (expect t)' as check,
  (select count(*) from public._diamond_reset_plan('2026-09', 'gift') where profile_id = 'd1000000-0000-0000-0000-0000000000d5') = 0 as no_ghost;
select '2c per wallet: h1 1000/500, h2 400, h3 1000, h4 500 (expect 1000, 500, 400, 1000, 500)' as check,
  (select amount from public._diamond_reset_plan('2026-09', 'gift') where profile_id = 'b1000000-0000-0000-0000-0000000000b1') as h1g,
  (select amount from public._diamond_reset_plan('2026-09', 'reward') where profile_id = 'b1000000-0000-0000-0000-0000000000b1') as h1r,
  (select amount from public._diamond_reset_plan('2026-09', 'gift') where profile_id = 'b2000000-0000-0000-0000-0000000000b2') as h2,
  (select amount from public._diamond_reset_plan('2026-09', 'gift') where profile_id = 'b3000000-0000-0000-0000-0000000000b3') as h3,
  (select amount from public._diamond_reset_plan('2026-09', 'gift') where profile_id = 'b4000000-0000-0000-0000-0000000000b4') as h4;

-- 3. checks before anything runs
select '3 a bad month, a bad button, an open month, a wrong confirmation (expect t, t, t, t)' as check,
  pg_temp.refused('select public.admin_reset_diamonds(''2026-9'', ''gift'', ''2026-9'')', '%YYYY-MM%') as bad_month,
  pg_temp.refused('select public.admin_reset_diamonds(''2026-09'', ''coins'', ''2026-09'')', '%Choose gifting%') as bad_source,
  pg_temp.refused(format('select public.admin_reset_diamonds(%L, ''gift'', %L)', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM'), to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM')), '%has not ended yet%') as open_month,
  pg_temp.refused('select public.admin_reset_diamonds(''2026-09'', ''gift'', ''yes'')', '%Type the month%') as wrong_confirm;
select '3b nothing moved yet (expect 2200, 400, 1300, 800, 0)' as check,
  pg_temp.dia('b1000000-0000-0000-0000-0000000000b1') as h1, pg_temp.dia('b2000000-0000-0000-0000-0000000000b2') as h2,
  pg_temp.dia('b3000000-0000-0000-0000-0000000000b3') as h3, pg_temp.dia('b4000000-0000-0000-0000-0000000000b4') as h4,
  (select count(*) from public.diamond_reset_runs) as runs;

-- 4. reset the GIFTING diamonds of September (a Super Admin this time)
select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e6');
create temp table runs as select public.admin_reset_diamonds('2026-09', 'gift', '2026-09') as r;
select '4 gifting reset: 4 wallets, 2900 diamonds (expect 1 run, 4, 2900)' as check, jsonb_array_length(r) as runs, (r -> 0 ->> 'wallets')::int as wallets, (r -> 0 ->> 'diamonds')::bigint as diamonds from runs;
select '4b balances after (expect 1200, 0, 300, 300, ghost 200)' as check,
  pg_temp.dia('b1000000-0000-0000-0000-0000000000b1') as h1, pg_temp.dia('b2000000-0000-0000-0000-0000000000b2') as h2,
  pg_temp.dia('b3000000-0000-0000-0000-0000000000b3') as h3, pg_temp.dia('b4000000-0000-0000-0000-0000000000b4') as h4,
  pg_temp.dia('d1000000-0000-0000-0000-0000000000d5') as ghost;
select '4c the ledger: 4 grant_reversal rows tied to the run, 2900 in total (expect 4, 2900)' as check, count(*) as n, -sum(amount) as total
  from public.wallet_ledger where reference_table = 'diamond_reset_runs' and kind = 'grant_reversal'
   and reference_id = (select (r -> 0 ->> 'run_id')::uuid from runs);
select '4d the run is logged and audited, critical (expect gift, 4, 2900, 1)' as check, r.source, r.wallets, r.diamonds,
  (select count(*) from public.audit_logs where action = 'diamonds.reset' and severity = 'critical') as audits
  from public.diamond_reset_runs r where r.period = '2026-09';
select '4e the Salary figure is unchanged: September gift diamonds of h1 still 1000 (expect 1000)' as check,
  (select sum(amount) from public.wallet_ledger where profile_id = 'b1000000-0000-0000-0000-0000000000b1' and kind = 'gift_received' and created_at >= '2026-08-31 18:30+00' and created_at < '2026-09-30 18:30+00') as sep_gifts;
select '4f no wallet is below 0 (expect t)' as check, (select min(diamonds) from public.wallets) >= 0 as ok;

-- 5. once only
select '5 the same button again, and "both" while gifting is done (expect t, t)' as check,
  pg_temp.refused('select public.admin_reset_diamonds(''2026-09'', ''gift'', ''2026-09'')', '%already reset%') as again,
  pg_temp.refused('select public.admin_reset_diamonds(''2026-09'', ''both'', ''2026-09'')', '%already reset%') as both_blocked;

-- 6. the REWARD diamonds of September
create temp table runs2 as select public.admin_reset_diamonds('2026-09', 'reward', '2026-09') as r;
select '6 reward reset: 1 wallet, 500 diamonds (expect 1, 500)' as check, (r -> 0 ->> 'wallets')::int as wallets, (r -> 0 ->> 'diamonds')::bigint as diamonds from runs2;
select '6b h1 is left with the August 700 only (expect 700)' as check, pg_temp.dia('b1000000-0000-0000-0000-0000000000b1') as h1;
select '6c the preview now says both done (expect t, t)' as check,
  (p -> 'gift' ->> 'done')::boolean as g, (p -> 'reward' ->> 'done')::boolean as r from (select public.admin_diamond_reset_preview('2026-09') as p) q;

-- 7. undo the gifting run: exact diamonds back, month free again
select '7 a wrong confirmation, then the undo itself (expect t)' as check,
  pg_temp.refused(format('select public.admin_undo_diamond_reset(%L, ''nope'')', (select (r -> 0 ->> 'run_id') from runs)), '%Type the month%') as ok;
create temp table undo as select public.admin_undo_diamond_reset((select (r -> 0 ->> 'run_id')::uuid from runs), '2026-09') as r from runs;
select '7b undone: 4 wallets, 2900 diamonds back (expect 4, 2900)' as check, (r ->> 'wallets')::int as wallets, (r ->> 'diamonds')::bigint as diamonds from undo;
select '7c balances are back (expect 1700, 400, 1300, 800)' as check,
  pg_temp.dia('b1000000-0000-0000-0000-0000000000b1') as h1, pg_temp.dia('b2000000-0000-0000-0000-0000000000b2') as h2,
  pg_temp.dia('b3000000-0000-0000-0000-0000000000b3') as h3, pg_temp.dia('b4000000-0000-0000-0000-0000000000b4') as h4;
select '7d a second undo is refused (expect t)' as check,
  pg_temp.refused(format('select public.admin_undo_diamond_reset(%L, ''2026-09'')', (select (r -> 0 ->> 'run_id') from runs)), '%already undone%') as ok;
select '7e the undo credits do not count as gifts or rewards (expect 1000 gifts, 500 rewards in September for h1)' as check,
  (select sum(amount) from public.wallet_ledger where profile_id = 'b1000000-0000-0000-0000-0000000000b1' and kind = 'gift_received' and created_at >= '2026-08-31 18:30+00' and created_at < '2026-09-30 18:30+00') as gifts,
  (select sum(amount) from public.wallet_ledger l where profile_id = 'b1000000-0000-0000-0000-0000000000b1' and kind = 'grant' and note = 'lucky_box' and created_at >= '2026-08-31 18:30+00' and created_at < '2026-09-30 18:30+00'
      and not exists (select 1 from public.wallet_ledger x where x.reference_table = 'wallet_ledger' and x.reference_id = l.id and x.kind = 'grant_reversal')) as rewards;
select '7f the month can be run again (expect 4 wallets)' as check, (public.admin_reset_diamonds('2026-09', 'gift', '2026-09') -> 0 ->> 'wallets')::int as wallets;

-- 8. "both" on its own month (July): gift and reward in one step
create temp table runs3 as select public.admin_reset_diamonds('2026-07', 'both', '2026-07') as r;
select '8 both: two runs, 300 gift + 200 reward, h5 is empty (expect 2, gift 300, reward 200, 0)' as check, jsonb_array_length(r) as runs,
  (select (x ->> 'diamonds')::bigint from jsonb_array_elements(r) x where x ->> 'source' = 'gift') as gift,
  (select (x ->> 'diamonds')::bigint from jsonb_array_elements(r) x where x ->> 'source' = 'reward') as reward,
  pg_temp.dia('b5000000-0000-0000-0000-0000000000b5') as h5 from runs3;

-- 9. the run log is readable by staff only
select pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
set role authenticated;
select '9 a plain user sees no runs (expect 0)' as check, count(*) as n from public.diamond_reset_runs;
reset role;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
set role authenticated;
select '9b a Master sees them (expect 5: Sep gift undone, Sep reward, Sep gift re-run, July gift, July reward)' as check, count(*) as n from public.diamond_reset_runs;
reset role;
select '9c writing directly is not possible (expect t)' as check,
  not has_table_privilege('authenticated', 'public.diamond_reset_runs', 'insert') and not has_table_privilege('authenticated', 'public.diamond_reset_runs', 'update') as ok;
