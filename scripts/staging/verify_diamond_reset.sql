-- Exercises the monthly diamond reset (20261026120000) on STAGING with the real roles and grants, then rolls back. Run through scripts/staging/verify_diamond_reset.sh.
-- It builds its own three hosts with a history in March 2026 (India time) so it cannot touch anything else, and it ends in ROLLBACK.
--   d1: Mar gifts 600+400, Lucky Box 500, Lucky Box 300 (pulled back)              -> balance 1500
--   d2: Mar gifts 1000, withdrew 600                                                -> balance 400
--   d3: Mar gifts 1000, Apr gift 300                                                -> balance 1300
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

do $$
declare
  master uuid := (select user_id from public.staff_roles where role = 'admin' order by user_id limit 1);
  super uuid := (select user_id from public.staff_roles where role = 'super_admin' order by user_id limit 1);
  d1 uuid := gen_random_uuid(); d2 uuid := gen_random_uuid(); d3 uuid := gen_random_uuid();
  ga uuid := gen_random_uuid(); plain uuid := gen_random_uuid();
begin
  if master is null or super is null then
    insert into res(step, ok, info) values ('setup: a Master and a Super Admin exist on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  insert into auth.users (id, aud, role, email, raw_user_meta_data) values
    (d1, 'authenticated', 'authenticated', 'zz-smoke-dr1@staging.sabalive.test', '{"name":"ZZ Diamonds One"}'),
    (d2, 'authenticated', 'authenticated', 'zz-smoke-dr2@staging.sabalive.test', '{"name":"ZZ Diamonds Two"}'),
    (d3, 'authenticated', 'authenticated', 'zz-smoke-dr3@staging.sabalive.test', '{"name":"ZZ Diamonds Three"}'),
    (ga, 'authenticated', 'authenticated', 'zz-smoke-drga@staging.sabalive.test', '{"name":"ZZ Global"}'),
    (plain, 'authenticated', 'authenticated', 'zz-smoke-drplain@staging.sabalive.test', '{"name":"ZZ Plain"}');
  insert into public.staff_roles (user_id, role) values (ga, 'global_admin');
  insert into public.wallet_ledger (id, profile_id, kind, currency, amount, note, created_at) values
    (gen_random_uuid(), d1, 'gift_received', 'diamonds', 600, null, '2026-03-10 12:00+00'),
    (gen_random_uuid(), d1, 'gift_received', 'diamonds', 400, null, '2026-03-11 12:00+00'),
    (gen_random_uuid(), d1, 'grant', 'diamonds', 500, 'lucky_box', '2026-03-12 12:00+00'),
    ('99999999-0000-0000-0000-0000000000a1', d1, 'grant', 'diamonds', 300, 'lucky_box', '2026-03-13 12:00+00'),
    (gen_random_uuid(), d2, 'gift_received', 'diamonds', 1000, null, '2026-03-10 12:00+00'),
    (gen_random_uuid(), d3, 'gift_received', 'diamonds', 1000, null, '2026-03-10 12:00+00');
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at) values
    (d1, 'grant_reversal', 'diamonds', -300, 'wallet_ledger', '99999999-0000-0000-0000-0000000000a1', 'pulled back', '2026-03-14 12:00+00'),
    (d2, 'withdrawal', 'diamonds', -600, 'withdrawals', null, 'paid', '2026-03-20 12:00+00'),
    (d3, 'gift_received', 'diamonds', 300, null, null, null, '2026-04-05 12:00+00');
  insert into ids values ('master', master::text), ('super', super::text), ('d1', d1::text), ('d2', d2::text), ('d3', d3::text), ('ga', ga::text), ('plain', plain::text);
  insert into res(step, ok, info) select '0 the setup balances are 1500 / 400 / 1300',
    (select diamonds from public.wallets where profile_id = d1) = 1500 and (select diamonds from public.wallets where profile_id = d2) = 400 and (select diamonds from public.wallets where profile_id = d3) = 1300, null;
end
$$;

set local role authenticated;
do $$
declare
  master uuid := (select val::uuid from ids where k = 'master');
  super uuid := (select val::uuid from ids where k = 'super');
  ga uuid := (select val::uuid from ids where k = 'ga');
  plain uuid := (select val::uuid from ids where k = 'plain');
  p jsonb; r jsonb;
begin
  if master is null then return; end if;

  perform set_config('request.jwt.claim.sub', ga::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', ga), true);
  begin perform public.admin_diamond_reset_preview('2026-03'); insert into res(step, ok, info) values ('1 a Global Admin cannot preview', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('1 a Global Admin cannot preview', sqlerrm like '%Only a Master or Super Admin%', sqlerrm); end;
  begin perform public.admin_reset_diamonds('2026-03', 'gift', '2026-03'); insert into res(step, ok, info) values ('1b ... or reset', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('1b ... or reset', sqlerrm like '%Only a Master or Super Admin%', sqlerrm); end;

  perform set_config('request.jwt.claim.sub', plain::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', plain), true);
  begin perform public.admin_reset_diamonds('2026-03', 'gift', '2026-03'); insert into res(step, ok, info) values ('1c an ordinary user cannot reset', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('1c an ordinary user cannot reset', sqlerrm like '%Only a Master or Super Admin%', sqlerrm); end;

  perform set_config('request.jwt.claim.sub', master::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', master), true);
  p := public.admin_diamond_reset_preview('2026-03');
  insert into res(step, ok, info) values ('2 a Master previews a finished month: at least our 3 wallets for gifts, 1 for rewards, nothing done yet',
    (p ->> 'ended')::boolean and (p -> 'gift' ->> 'wallets')::int >= 3 and (p -> 'reward' ->> 'wallets')::int >= 1 and not (p -> 'gift' ->> 'done')::boolean, p::text);
  begin perform public.admin_reset_diamonds('2026-03', 'gift', 'wrong'); insert into res(step, ok, info) values ('2b a wrong confirmation is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('2b a wrong confirmation is refused', sqlerrm like '%Type the month%', sqlerrm); end;
  begin perform public.admin_reset_diamonds(to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM'), 'gift', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM')); insert into res(step, ok, info) values ('2c the month in progress is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('2c the month in progress is refused', sqlerrm like '%has not ended yet%', sqlerrm); end;

  -- the Super Admin presses the gifting button
  perform set_config('request.jwt.claim.sub', super::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', super), true);
  r := public.admin_reset_diamonds('2026-03', 'gift', '2026-03');
  insert into ids values ('gift_run', r -> 0 ->> 'run_id');
  insert into res(step, ok, info) values ('3 the Super Admin resets the gifting diamonds of March', (r -> 0 ->> 'wallets')::int >= 3 and (r -> 0 ->> 'diamonds')::bigint >= 2400, r::text);
end
$$;

reset role;
insert into res(step, ok, info)
  select '3b our wallets: 500 (kept the reward), 0 (had withdrawn), 300 (the April gift stays)',
    (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd1')) = 500
    and (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd2')) = 0
    and (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd3')) = 300, null
   where exists (select 1 from ids where k = 'd1');
insert into res(step, ok, info)
  select '3c the ledger rows are grant_reversal, tied to the run: 1000, 400, 1000',
    (select string_agg((-amount)::text, ',' order by (-amount) desc, profile_id::text) from public.wallet_ledger
      where reference_table = 'diamond_reset_runs' and reference_id = (select val::uuid from ids where k = 'gift_run') and kind = 'grant_reversal'
        and profile_id in (select val::uuid from ids where k in ('d1', 'd2', 'd3'))) = '1000,1000,400', null
   where exists (select 1 from ids where k = 'gift_run');
insert into res(step, ok, info)
  select '3d the hosts got the standard "reclaimed by an admin" notification (400 for d2, 1000 for d3)',
    exists (select 1 from public.notifications where profile_id = (select val::uuid from ids where k = 'd2') and kind = 'coins_grant_reversal' and body like '400 diamonds were reclaimed%')
    and exists (select 1 from public.notifications where profile_id = (select val::uuid from ids where k = 'd3') and kind = 'coins_grant_reversal' and body like '1000 diamonds were reclaimed%'), null
   where exists (select 1 from ids where k = 'gift_run');

set local role authenticated;
do $$
declare
  master uuid := (select val::uuid from ids where k = 'master');
  super uuid := (select val::uuid from ids where k = 'super');
  r jsonb; u jsonb;
begin
  if master is null or not exists (select 1 from ids where k = 'gift_run') then return; end if;
  perform set_config('request.jwt.claim.sub', master::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', master), true);
  begin perform public.admin_reset_diamonds('2026-03', 'gift', '2026-03'); insert into res(step, ok, info) values ('4 the same button again is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('4 the same button again is refused', sqlerrm like '%already reset%', sqlerrm); end;
  begin perform public.admin_reset_diamonds('2026-03', 'both', '2026-03'); insert into res(step, ok, info) values ('4b "both" is refused while one is done', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('4b "both" is refused while one is done', sqlerrm like '%already reset%', sqlerrm); end;
  r := public.admin_reset_diamonds('2026-03', 'reward', '2026-03');
  insert into ids values ('reward_run', r -> 0 ->> 'run_id');
  insert into res(step, ok, info) values ('5 a Master resets the reward diamonds of March', (r -> 0 ->> 'wallets')::int >= 1 and (r -> 0 ->> 'diamonds')::bigint >= 500, r::text);

  perform set_config('request.jwt.claim.sub', super::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', super), true);
  begin perform public.admin_undo_diamond_reset((select val::uuid from ids where k = 'gift_run'), 'wrong'); insert into res(step, ok, info) values ('6 undo needs the month typed', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('6 undo needs the month typed', sqlerrm like '%Type the month%', sqlerrm); end;
  u := public.admin_undo_diamond_reset((select val::uuid from ids where k = 'gift_run'), '2026-03');
  insert into res(step, ok, info) values ('6b the gifting run is undone', (u ->> 'wallets')::int >= 3 and (u ->> 'diamonds')::bigint >= 2400, u::text);
  begin perform public.admin_undo_diamond_reset((select val::uuid from ids where k = 'gift_run'), '2026-03'); insert into res(step, ok, info) values ('6c a second undo is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('6c a second undo is refused', sqlerrm like '%already undone%', sqlerrm); end;
end
$$;

reset role;
insert into res(step, ok, info)
  select '6d after the reward reset and the gifting undo: 1000 (500-500+1000), 400, 1300',
    (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd1')) = 1000
    and (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd2')) = 400
    and (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd3')) = 1300, null
   where exists (select 1 from ids where k = 'reward_run');
insert into res(step, ok, info)
  select '7 the Salary figures are untouched: March gifts of d1 still 1000, rewards still 500 (the pulled-back win left out)',
    (select sum(amount) from public.wallet_ledger where profile_id = (select val::uuid from ids where k = 'd1') and kind = 'gift_received' and created_at >= '2026-02-28 18:30+00' and created_at < '2026-03-31 18:30+00') = 1000
    and (select sum(l.amount) from public.wallet_ledger l where l.profile_id = (select val::uuid from ids where k = 'd1') and l.kind = 'grant' and l.note = 'lucky_box'
          and l.created_at >= '2026-02-28 18:30+00' and l.created_at < '2026-03-31 18:30+00'
          and not exists (select 1 from public.wallet_ledger x where x.reference_table = 'wallet_ledger' and x.reference_id = l.id and x.kind = 'grant_reversal')) = 500, null
   where exists (select 1 from ids where k = 'd1');
insert into res(step, ok, info)
  select '8 three critical audit rows (reset gifting, reset rewards, undo)',
    (select count(*) from public.audit_logs where severity = 'critical' and action in ('diamonds.reset', 'diamonds.reset_undone') and created_at >= now() - interval '1 minute') = 3, null
   where exists (select 1 from ids where k = 'reward_run');
insert into res(step, ok, info) select '9 no wallet is below 0', (select min(diamonds) from public.wallets) >= 0, null;
insert into res(step, ok, info) values ('10 anon cannot call the functions; app users cannot call the internals',
  not has_function_privilege('anon', 'public.admin_reset_diamonds(text,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.admin_diamond_reset_preview(text)', 'execute')
  and not has_function_privilege('authenticated', 'public._diamond_reset_plan(text,text)', 'execute'), null);

-- ---------------------------------------------------------------- the AUTOMATIC reset (20261026130000)
-- state here: the gifting run of March was undone (its slot is free), the reward run is active
insert into res(step, ok, info)
  select '11 the automatic reset is OFF by default or was left as the owner set it (the row exists)', (select count(*) from public.diamond_reset_settings) = 1, null;
set local role authenticated;
do $$
declare
  master uuid := (select val::uuid from ids where k = 'master');
  ga uuid := (select val::uuid from ids where k = 'ga');
  r jsonb;
begin
  if master is null or not exists (select 1 from ids where k = 'reward_run') then return; end if;
  perform set_config('request.jwt.claim.sub', ga::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', ga), true);
  begin perform public.admin_set_diamond_reset_auto(true, true, true, 1); insert into res(step, ok, info) values ('11b a Global Admin cannot change the automatic reset', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('11b a Global Admin cannot change the automatic reset', sqlerrm like '%Only a Master or Super Admin%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', master::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', master), true);
  begin perform public.admin_set_diamond_reset_auto(true, false, false, 1); insert into res(step, ok, info) values ('11c ON with no box ticked is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('11c ON with no box ticked is refused', sqlerrm like '%Tick at least one%', sqlerrm); end;
  begin perform public.admin_set_diamond_reset_auto(true, true, true, 29); insert into res(step, ok, info) values ('11d a day above 28 is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('11d a day above 28 is refused', sqlerrm like '%from 1 to 28%', sqlerrm); end;
  r := public.admin_set_diamond_reset_auto(true, true, false, 1);
  insert into res(step, ok, info) values ('11e a Master switches it ON for gifting only, day 1', (r ->> 'enabled')::boolean and (r ->> 'reset_gift')::boolean and not (r ->> 'reset_reward')::boolean and (r ->> 'run_day')::int = 1, r::text);
end
$$;
reset role;
do $$
declare
  r jsonb;
  u1 uuid := (select val::uuid from ids where k = 'd1');
begin
  if u1 is null or not exists (select 1 from ids where k = 'reward_run') then return; end if;
  -- 2026-04-01 18:40 UTC is 02 Apr 00:10 in India: not the day
  r := public.run_diamond_reset_auto('2026-04-01 18:40+00');
  insert into res(step, ok, info) values ('12 on the wrong day the job does nothing', (r ->> 'ran')::boolean is false and r ->> 'why' = 'not the day', r::text);
  -- 2026-03-31 18:40 UTC is 01 Apr 00:10 in India: the day, so it resets March
  r := public.run_diamond_reset_auto('2026-03-31 18:40+00');
  insert into res(step, ok, info) values ('13 on the day it resets the month before (March), gifting only', (r ->> 'ran')::boolean and r ->> 'period' = '2026-03', r::text);
  insert into res(step, ok, info)
    select '13b the run is marked automatic, has no person, and the reward run was not repeated',
      (select count(*) from public.diamond_reset_runs where period = '2026-03' and source = 'gift' and undone_at is null and auto and run_by is null) = 1
      and (select count(*) from public.diamond_reset_runs where period = '2026-03' and source = 'reward' and undone_at is null) = 1, null;
  insert into res(step, ok, info)
    select '13c our wallets: 0, 0, 300 (the April gift stays)',
      (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd1')) = 0
      and (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd2')) = 0
      and (select diamonds from public.wallets where profile_id = (select val::uuid from ids where k = 'd3')) = 300, null;
  r := public.run_diamond_reset_auto('2026-03-31 18:50+00');
  insert into res(step, ok, info) values ('14 the job again the same day takes nothing more', (select count(*) from public.diamond_reset_runs where period = '2026-03' and source = 'gift' and undone_at is null) = 1 and r::text like '%already reset%', r::text);
  insert into res(step, ok, info) select '15 the settings say what the job did', last_auto_at is not null and last_auto_note like '2026-03 - gift:%', last_auto_note from public.diamond_reset_settings;
  insert into res(step, ok, info) select '16 the audit log has the automatic run, with no person', count(*) >= 1, null from public.audit_logs where action = 'diamonds.reset_auto' and actor_id is null and severity = 'critical';
end
$$;
set local role authenticated;
do $$
declare
  master uuid := (select val::uuid from ids where k = 'master');
begin
  if master is null or not exists (select 1 from ids where k = 'reward_run') then return; end if;
  perform set_config('request.jwt.claim.sub', master::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', master), true);
  perform public.admin_set_diamond_reset_auto(false, true, false, 1);
end
$$;
reset role;
insert into res(step, ok, info)
  select '17 switched OFF, the job does nothing', public.run_diamond_reset_auto('2026-03-31 18:40+00') ->> 'why' = 'off', null
   where exists (select 1 from ids where k = 'reward_run');
insert into res(step, ok, info) values ('18 the job and the shared function are not callable by app users or anon',
  not has_function_privilege('authenticated', 'public.run_diamond_reset_auto(timestamptz)', 'execute')
  and not has_function_privilege('anon', 'public.run_diamond_reset_auto(timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'public._diamond_reset_run_one(text,text,uuid,boolean)', 'execute')
  and not has_function_privilege('anon', 'public.admin_set_diamond_reset_auto(boolean,boolean,boolean,integer)', 'execute'), null);
insert into res(step, ok, info)
  select '19 the daily job is scheduled (00:05 India time = 18:35 UTC)', exists (select 1 from cron.job where jobname = 'diamond-reset-auto' and schedule = '35 18 * * *'), null;

select n, step, ok, info from res order by n;

rollback;
