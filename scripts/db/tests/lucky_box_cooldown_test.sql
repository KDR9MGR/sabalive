-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/lucky_box_cooldown_test.sql
-- Proves the 24 h cooldown: a quick restart is not paid twice, a host is paid again after the cooldown, a live that
-- reaches the duration while resting is never paid later, a pulled-back reward still counts, 0 turns it off, and the
-- status function tells the app what to show.
insert into auth.users (id, email) values
  ('a8000000-0000-0000-0000-000000000001', 'hostA@x'),   -- the 100490 story: restart after a drop
  ('b8000000-0000-0000-0000-000000000002', 'hostB@x'),   -- paid 23 h ago
  ('c8000000-0000-0000-0000-000000000003', 'hostC@x'),   -- paid 26 h ago
  ('d8000000-0000-0000-0000-000000000004', 'hostD@x'),   -- reward pulled back
  ('e8000000-0000-0000-0000-000000000005', 'viewer@x');
select '0 default cooldown is 24 (expect 24)' as check, cooldown_hours as n from public.lucky_box_config;

-- host A: live 1 started 2 h ago -> paid; it ends; live 2 started 1 h ago (the quick restart)
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at)
values ('a1111111-1111-1111-1111-111111111111', 'a8000000-0000-0000-0000-000000000001', 'A1', 'live', 'video', now() - interval '2 hours', now());
select public.grant_lucky_box_rewards();
select '1 live 1 is paid (expect 1)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box' and profile_id = 'a8000000-0000-0000-0000-000000000001';
update public.live_streams set status = 'ended', ended_at = now() where id = 'a1111111-1111-1111-1111-111111111111';
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at)
values ('a2222222-2222-2222-2222-222222222222', 'a8000000-0000-0000-0000-000000000001', 'A2', 'live', 'video', now() - interval '1 hour', now());
select public.grant_lucky_box_rewards();
select '2 the restarted live is NOT paid (expect 1 reward in total)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box' and profile_id = 'a8000000-0000-0000-0000-000000000001';

-- the status function: viewer asks about live 2 (resting) and live 1 (paid)
select set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000005', false);
select '3 live 2 reports a rest period that ends in about 24 h (expect t)' as check,
       (public.lucky_box_status('a2222222-2222-2222-2222-222222222222') ->> 'rest_until')::timestamptz > now() + interval '22 hours' as ok;
select '3 live 2 is not paid (expect f)' as check, (public.lucky_box_status('a2222222-2222-2222-2222-222222222222') ->> 'paid')::boolean as paid;
select '3 live 1 is paid and not resting (expect t, null)' as check,
       (public.lucky_box_status('a1111111-1111-1111-1111-111111111111') ->> 'paid')::boolean as paid,
       public.lucky_box_status('a1111111-1111-1111-1111-111111111111') -> 'rest_until' as rest;
select '3 an unknown live gives null (expect t)' as check, public.lucky_box_status(gen_random_uuid()) is null as ok;
select set_config('request.jwt.claim.sub', '', false);

-- 25 hours later (the first reward moved back in time): live 2, still on, is due and now allowed? Its due moment
-- (start + 40 min = 20 min ago) is more than 24 h after a reward made 25 h ago -> paid.
update public.wallet_ledger set created_at = now() - interval '25 hours' where note = 'lucky_box' and profile_id = 'a8000000-0000-0000-0000-000000000001';
select public.grant_lucky_box_rewards();
select '4 after the cooldown the next live is paid (expect 2 rewards in total)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box' and profile_id = 'a8000000-0000-0000-0000-000000000001';

-- host B: paid 23 h ago, new live reached 40 minutes -> blocked, and STILL not paid on a later run
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
  values ('b8000000-0000-0000-0000-000000000002', 'grant', 'diamonds', 3000, 'live_streams', gen_random_uuid(), 'lucky_box', now() - interval '23 hours');
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at)
values ('b1111111-1111-1111-1111-111111111111', 'b8000000-0000-0000-0000-000000000002', 'B1', 'live', 'video', now() - interval '2 hours', now());
select public.grant_lucky_box_rewards();
select '5 host B (paid 23 h ago) is blocked (expect 1 reward in total)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box' and profile_id = 'b8000000-0000-0000-0000-000000000002';
-- two hours pass: the cooldown (ends in 1 h) is over by then, but this live's box opened during the rest -> still nothing
update public.wallet_ledger set created_at = created_at - interval '2 hours' where note = 'lucky_box' and profile_id = 'b8000000-0000-0000-0000-000000000002';
select public.grant_lucky_box_rewards();
select '5 a live whose box opened while resting is not paid later either (expect 1)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box' and profile_id = 'b8000000-0000-0000-0000-000000000002';

-- host C: paid 26 h ago -> paid again (the box opens 1h20m ago, so that reward is 24h40m older than the moment it opens)
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
  values ('c8000000-0000-0000-0000-000000000003', 'grant', 'diamonds', 3000, 'live_streams', gen_random_uuid(), 'lucky_box', now() - interval '26 hours');
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at)
values ('c1111111-1111-1111-1111-111111111111', 'c8000000-0000-0000-0000-000000000003', 'C1', 'live', 'video', now() - interval '2 hours', now());
select public.grant_lucky_box_rewards();
select '6 host C (paid 26 h ago) is paid again (expect 2)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box' and profile_id = 'c8000000-0000-0000-0000-000000000003';

-- host D: a reward that was pulled back still counts as paid
insert into public.wallet_ledger (id, profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
  values ('d9999999-9999-9999-9999-999999999999', 'd8000000-0000-0000-0000-000000000004', 'grant', 'diamonds', 3000, 'live_streams', gen_random_uuid(), 'lucky_box', now() - interval '3 hours');
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
  values ('d8000000-0000-0000-0000-000000000004', 'grant_reversal', 'diamonds', -3000, 'wallet_ledger', 'd9999999-9999-9999-9999-999999999999', 'Pulled back: Lucky Box reward');
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at)
values ('d1111111-1111-1111-1111-111111111111', 'd8000000-0000-0000-0000-000000000004', 'D1', 'live', 'video', now() - interval '2 hours', now());
select public.grant_lucky_box_rewards();
select '7 a pulled-back reward still counts: host D is not paid (expect 1 win row)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box' and profile_id = 'd8000000-0000-0000-0000-000000000004';

-- cooldown 0 = off: host D is paid for the live now
update public.lucky_box_config set cooldown_hours = 0;
select public.grant_lucky_box_rewards();
select '8 with the cooldown off host D is paid (expect 2 win rows)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box' and profile_id = 'd8000000-0000-0000-0000-000000000004';
select '8 status shows no rest when it is off (expect t)' as check, public.lucky_box_status('b1111111-1111-1111-1111-111111111111') -> 'rest_until' = 'null'::jsonb as ok;

-- the setting is bounded
do $$ begin
  update public.lucky_box_config set cooldown_hours = -1;
  raise exception 'expected a check violation';
exception when check_violation then null; end $$;
select '9 negative cooldowns are refused (expect t)' as check, true as ok;
