-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/lucky_box_pull_back_test.sql
-- Proves: a Lucky Box win can be pulled back once by a Master, not by anyone else, not when the host already spent
-- the diamonds, and the cron never pays the same stream twice afterwards.
insert into auth.users (id, email) values
  ('a7000000-0000-0000-0000-000000000001', 'host7@x'),
  ('b7000000-0000-0000-0000-000000000002', 'master7@x'),
  ('c7000000-0000-0000-0000-000000000003', 'nobody7@x');
insert into public.staff_roles (user_id, role) values ('b7000000-0000-0000-0000-000000000002', 'admin');
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at)
values ('77777777-7777-7777-7777-777777777777', 'a7000000-0000-0000-0000-000000000001', 'box test', 'live', 'video',
        now() - interval '2 hours', now());

-- the cron pays the win
select public.grant_lucky_box_rewards();
select '1 host was paid (expect 3000 or the configured reward)' as check, diamonds as n
  from public.wallets where profile_id = 'a7000000-0000-0000-0000-000000000001';

-- someone who is not staff is refused
select set_config('request.jwt.claim.sub', 'c7000000-0000-0000-0000-000000000003', false);
do $$ declare v uuid; begin
  select id into v from public.wallet_ledger where note = 'lucky_box';
  perform public.lucky_box_pull_back(v);
  raise exception 'expected a refusal';
exception when others then
  if sqlerrm not like 'Only a Master%' then raise; end if;
end $$;
select '2 a non-staff user is refused (expect t)' as check, true as ok;

-- the Master pulls it back
select set_config('request.jwt.claim.sub', 'b7000000-0000-0000-0000-000000000002', false);
select public.lucky_box_pull_back((select id from public.wallet_ledger where note = 'lucky_box'));
select '3 host is back to 0 (expect 0)' as check, diamonds as n from public.wallets where profile_id = 'a7000000-0000-0000-0000-000000000001';
select '3 one reversal row, tied to the win, not tagged lucky_box (expect 1, t)' as check, count(*) as n,
       bool_and(note is distinct from 'lucky_box' and reference_table = 'wallet_ledger') as ok
  from public.wallet_ledger where kind = 'grant_reversal';
select '3 audited (expect 1)' as check, count(*) as n from public.audit_logs where action = 'lucky_box.pull_back';

-- only once
do $$ declare v uuid; begin
  select id into v from public.wallet_ledger where note = 'lucky_box';
  perform public.lucky_box_pull_back(v);
  raise exception 'expected a refusal';
exception when others then
  if sqlerrm <> 'This reward has already been pulled back' then raise; end if;
end $$;
select '4 a second pull back is refused (expect t)' as check, true as ok;

-- the cron does not pay that stream again
select set_config('request.jwt.claim.sub', '', false);
select public.grant_lucky_box_rewards();
select '5 the cron paid nothing new (expect 1 win in total)' as check, count(*) as n from public.wallet_ledger where note = 'lucky_box';
select '5 host still 0 (expect 0)' as check, diamonds as n from public.wallets where profile_id = 'a7000000-0000-0000-0000-000000000001';

-- a host who already spent the diamonds: refused with the numbers
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at)
values ('88888888-8888-8888-8888-888888888888', 'a7000000-0000-0000-0000-000000000001', 'box test 2', 'live', 'video',
        now() - interval '2 hours', now());
select public.grant_lucky_box_rewards();
update public.live_streams set status = 'ended', ended_at = now() where id = '77777777-7777-7777-7777-777777777777';
insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
  values ('a7000000-0000-0000-0000-000000000001', 'withdrawal', 'diamonds', -2500, 'spent');
select set_config('request.jwt.claim.sub', 'b7000000-0000-0000-0000-000000000002', false);
do $$ declare v uuid; begin
  select id into v from public.wallet_ledger where note = 'lucky_box' and reference_id = '88888888-8888-8888-8888-888888888888';
  perform public.lucky_box_pull_back(v);
  raise exception 'expected a refusal';
exception when others then
  if sqlerrm not like 'Cannot pull back%' then raise; end if;
end $$;
select '6 already-spent diamonds block the pull back (expect t)' as check, true as ok;
