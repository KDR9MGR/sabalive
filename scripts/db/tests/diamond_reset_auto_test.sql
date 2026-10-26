-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/diamond_reset_auto_test.sql
-- Proves (20261026130000): the automatic reset is OFF by default; only a Master / Super Admin can change it; "on" needs a box ticked and a day from 1 to 28; the job does nothing
-- while off, on the wrong day, or for a month that has not ended; on the day it resets the PREVIOUS month for each ticked kind only, marks the runs automatic (no person),
-- leaves a kind that was already reset alone, never twice; one kind can be added later; it records what it did; nothing here is callable by app users or anon.
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-0000000000a1', 'master@x'),
  ('e1000000-0000-0000-0000-0000000000e6', 'super@x'),
  ('f1000000-0000-0000-0000-0000000000f7', 'global@x'),
  ('c1000000-0000-0000-0000-0000000000c1', 'plain@x'),
  ('b1000000-0000-0000-0000-0000000000b1', 'h1@x'),
  ('b2000000-0000-0000-0000-0000000000b2', 'h2@x');
insert into public.staff_roles (user_id, role) values
  ('a1000000-0000-0000-0000-0000000000a1', 'admin'),
  ('e1000000-0000-0000-0000-0000000000e6', 'super_admin'),
  ('f1000000-0000-0000-0000-0000000000f7', 'global_admin');
-- January 2026 (India time): h1 gifts 500 + Lucky Box 200, h2 gifts 300
insert into public.wallet_ledger (profile_id, kind, currency, amount, note, created_at) values
  ('b1000000-0000-0000-0000-0000000000b1', 'gift_received', 'diamonds', 500, null, '2026-01-10 12:00+00'),
  ('b1000000-0000-0000-0000-0000000000b1', 'grant', 'diamonds', 200, 'lucky_box', '2026-01-11 12:00+00'),
  ('b2000000-0000-0000-0000-0000000000b2', 'gift_received', 'diamonds', 300, null, '2026-01-10 12:00+00');

create or replace function pg_temp.as_user(p_id text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_id, false); $$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
create or replace function pg_temp.dia(p_id text) returns bigint language sql as $$ select diamonds from public.wallets where profile_id = p_id::uuid; $$;

-- 1. the defaults
select '1 off by default, both boxes ticked, day 1, nothing run yet (expect f, t, t, 1, t)' as check,
  enabled, reset_gift, reset_reward, run_day, last_auto_at is null as never_ran from public.diamond_reset_settings;
select '1b exactly one settings row (expect 1)' as check, count(*) as n from public.diamond_reset_settings;

-- 2. who may change it, and what is refused
select pg_temp.as_user('f1000000-0000-0000-0000-0000000000f7');
select '2 a Global Admin is refused (expect t)' as check, pg_temp.refused('select public.admin_set_diamond_reset_auto(true, true, true, 1)', '%Only a Master or Super Admin%') as ok;
select pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
select '2a ... and a plain user (expect t)' as check, pg_temp.refused('select public.admin_set_diamond_reset_auto(true, true, true, 1)', '%Only a Master or Super Admin%') as ok;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select '2b bad day, and ON with nothing ticked (expect t, t, t)' as check,
  pg_temp.refused('select public.admin_set_diamond_reset_auto(true, true, true, 0)', '%from 1 to 28%') as day0,
  pg_temp.refused('select public.admin_set_diamond_reset_auto(true, true, true, 29)', '%from 1 to 28%') as day29,
  pg_temp.refused('select public.admin_set_diamond_reset_auto(true, false, false, 1)', '%Tick at least one%') as none;
select '2c OFF with nothing ticked is allowed (expect f)' as check, (public.admin_set_diamond_reset_auto(false, false, false, 1) ->> 'enabled')::boolean as enabled;

-- 3. the job does nothing while the switch is off
select '3 off: nothing happens (expect f, off, 0 runs)' as check,
  (r ->> 'ran')::boolean as ran, r ->> 'why' as why, (select count(*) from public.diamond_reset_runs) as runs
  from (select public.run_diamond_reset_auto('2026-01-31 18:40+00') as r) q;

-- 4. ON, gifting only, day 1. 2026-01-31 18:40 UTC is 00:10 on 1 February in India: the job resets January.
select '4 switch on (gifting only, day 1) (expect t, t, f, 1)' as check,
  (r ->> 'enabled')::boolean as enabled, (r ->> 'reset_gift')::boolean as gift, (r ->> 'reset_reward')::boolean as reward, (r ->> 'run_day')::int as day
  from (select public.admin_set_diamond_reset_auto(true, true, false, 1) as r) q;
select '4b the audit row for the change, critical when switched on (expect 1)' as check, count(*) as n
  from public.audit_logs where action = 'diamonds.reset_auto_settings' and severity = 'critical' and target like 'ON: gifting yes, reward no, day 1%';
select '4c the wrong day does nothing (1 Feb 18:40 UTC = 2 Feb in India) (expect f, not the day)' as check,
  (r ->> 'ran')::boolean as ran, r ->> 'why' as why from (select public.run_diamond_reset_auto('2026-02-01 18:40+00') as r) q;
select '4d a month that has not ended is never touched (a clock two months ahead, on the chosen day) (expect f, month not ended)' as check,
  (r ->> 'ran')::boolean as ran, r ->> 'why' as why
  from (select public.run_diamond_reset_auto((date_trunc('month', now() at time zone 'Asia/Kolkata') + interval '2 months' + interval '10 minutes') at time zone 'Asia/Kolkata') as r) q;
select '4e still nothing run (expect 0)' as check, count(*) as n from public.diamond_reset_runs;

-- 5. the real run
select '5 on the day: January, gifting only (expect t, 2026-01)' as check, (r ->> 'ran')::boolean as ran, r ->> 'period' as period
  from (select public.run_diamond_reset_auto('2026-01-31 18:40+00') as r) q;
select '5b one automatic run, gifting, no person, 2 wallets, 800 diamonds (expect gift, t, t, 2, 800)' as check,
  source, auto, run_by is null as no_person, wallets, diamonds from public.diamond_reset_runs where period = '2026-01';
select '5c balances: h1 keeps the 200 reward, h2 is empty (expect 200, 0)' as check,
  pg_temp.dia('b1000000-0000-0000-0000-0000000000b1') as h1, pg_temp.dia('b2000000-0000-0000-0000-0000000000b2') as h2;
select '5d the audit row has no actor and is critical (expect 1)' as check, count(*) as n
  from public.audit_logs where action = 'diamonds.reset_auto' and actor_id is null and severity = 'critical';
select '5e the settings say what happened (expect a January note with gift 800 diamonds from 2 wallets)' as check,
  last_auto_at is not null as stamped, last_auto_note from public.diamond_reset_settings;

-- 6. never twice
select '6 the same day again changes nothing (expect 1 run, note says already reset)' as check,
  (select count(*) from public.diamond_reset_runs) as runs, r ->> 'notes' as notes
  from (select public.run_diamond_reset_auto('2026-01-31 18:50+00') as r) q;

-- 7. tick reward too: only the missing kind runs
select public.admin_set_diamond_reset_auto(true, true, true, 1);
create temp table job7 as select public.run_diamond_reset_auto('2026-01-31 19:00+00') as r;
select '7 both ticked: gifting is left alone, reward runs (expect 2 runs, reward 200 diamonds, 1 gifting run, h1 now 0)' as check,
  (select count(*) from public.diamond_reset_runs) as runs,
  (select diamonds from public.diamond_reset_runs where source = 'reward') as reward_diamonds,
  (select count(*) from public.diamond_reset_runs where source = 'gift') as gift_runs,
  pg_temp.dia('b1000000-0000-0000-0000-0000000000b1') as h1,
  (select r ->> 'notes' from job7) as notes;

-- 8. a month already reset by a person is left alone, and an Undo opens it for the next run
select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e6');
select '8 the Super Admin undoes the automatic gifting run: diamonds are back (expect 800 back, h2 300)' as check,
  (public.admin_undo_diamond_reset((select id from public.diamond_reset_runs where source = 'gift' and auto), '2026-01') ->> 'diamonds')::bigint as back,
  pg_temp.dia('b2000000-0000-0000-0000-0000000000b2') as h2;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select '8b the manual button on the same month: gifting is free again, reward is done (expect t, t)' as check,
  (public.admin_reset_diamonds('2026-01', 'gift', '2026-01') -> 0 ->> 'diamonds')::bigint = 800 as gift_by_hand,
  pg_temp.refused('select public.admin_reset_diamonds(''2026-01'', ''reward'', ''2026-01'')', '%already reset%') as reward_blocked;
select '8c the manual run names its person and is not automatic (expect f, t)' as check, auto, run_by is not null as has_person
  from public.diamond_reset_runs where source = 'gift' and undone_at is null;

-- 9. switch it off: nothing more happens
select public.admin_set_diamond_reset_auto(false, true, true, 1);
select '9 off again: nothing happens (expect f, off)' as check, (r ->> 'ran')::boolean as ran, r ->> 'why' as why
  from (select public.run_diamond_reset_auto('2026-01-31 18:40+00') as r) q;

-- 10. permissions
select '10 app users and anon cannot call the job or the shared function; anon cannot change the switch (expect all f)' as check,
  has_function_privilege('authenticated', 'public.run_diamond_reset_auto(timestamptz)', 'execute') as a1,
  has_function_privilege('anon', 'public.run_diamond_reset_auto(timestamptz)', 'execute') as a2,
  has_function_privilege('authenticated', 'public._diamond_reset_run_one(text,text,uuid,boolean)', 'execute') as a3,
  has_function_privilege('anon', 'public.admin_set_diamond_reset_auto(boolean,boolean,boolean,integer)', 'execute') as a4;
set role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select '10b staff read the settings (expect 1)' as check, count(*) as staff_sees from public.diamond_reset_settings;
select pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
select '10c a plain user sees nothing (expect 0)' as check, count(*) as plain_sees from public.diamond_reset_settings;
reset role;
select '10d nobody writes the settings directly (expect t)' as check, not has_table_privilege('authenticated', 'public.diamond_reset_settings', 'update') and not has_table_privilege('authenticated', 'public.diamond_reset_settings', 'insert') as ok;
