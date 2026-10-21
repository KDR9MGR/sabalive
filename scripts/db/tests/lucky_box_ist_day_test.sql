-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/lucky_box_ist_day_test.sql
-- Proves (20261021150000): with cooldown_mode = 'ist_day' a host gets ONE box per India calendar day, whoever pays it; the day is the day the
-- box OPENS (not when it was paid, so 23:00 and 23:30 starts fall on different days); a pulled-back box still uses up the day; the app status
-- says "resting until the next IST midnight"; the Live history says "cooldown" without an hours figure; 'hours' mode still works; the
-- automatic payout follows the same day rule; the helpers are not callable by app users.
insert into auth.users (id, email) values
  ('b9000000-0000-0000-0000-000000000001', 'master@x'),
  ('a1000000-0000-0000-0000-000000000001', 'h1@x'),
  ('a2000000-0000-0000-0000-000000000002', 'h2@x'),
  ('a3000000-0000-0000-0000-000000000003', 'h3@x'),
  ('a5000000-0000-0000-0000-000000000005', 'h5@x'),
  ('e9000000-0000-0000-0000-000000000009', 'viewer@x');
insert into public.staff_roles (user_id, role) values ('b9000000-0000-0000-0000-000000000001', 'admin');

select '0 the live row is in day mode after the migration (expect ist_day)' as check, cooldown_mode as n from public.lucky_box_config;

-- an ended video live that kept sending for 90 minutes, started at an IST clock time on a given day
create or replace function pg_temp.live(p_id text, p_host text, p_day date, p_time text) returns void language sql as $$
  insert into public.live_streams (id, host_id, title, status, mode, started_at, ended_at, last_heartbeat_at)
  select ('f0000000-0000-0000-0000-' || p_id)::uuid, ('a' || p_host || '000000-0000-0000-0000-00000000000' || p_host)::uuid, 't', 'ended', 'video', ts, ts + interval '90 minutes', ts + interval '90 minutes'
    from (select ((p_day + p_time::time)::timestamp at time zone 'Asia/Kolkata') as ts) x;
$$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

create temp table d as select (now() at time zone 'Asia/Kolkata')::date as today;
-- H1: two lives on D-3 (10:00 and 15:00), one on D-2
select pg_temp.live('000000000a01', '1', (select today - 3 from d), '10:00');
select pg_temp.live('000000000a02', '1', (select today - 3 from d), '15:00');
select pg_temp.live('000000000a03', '1', (select today - 2 from d), '10:00');
-- H2: 23:00 and 23:30 on D-3: the boxes open at 23:40 (D-3) and 00:10 (D-2): two different days
select pg_temp.live('000000000b01', '2', (select today - 3 from d), '23:00');
select pg_temp.live('000000000b02', '2', (select today - 3 from d), '23:30');
-- H3: a box on D-3 that is pulled back, then a second live the same day
select pg_temp.live('000000000c01', '3', (select today - 3 from d), '10:00');
select pg_temp.live('000000000c02', '3', (select today - 3 from d), '16:00');

select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000001', false);
-- 1. H1
select '1 first box of D-3 is paid (expect 3000)' as check, (public.lucky_box_pay_now('f0000000-0000-0000-0000-000000000a01') ->> 'diamonds')::int as n;
select '1b a second box the same IST day is refused (expect t)' as check,
       pg_temp.refused('select public.lucky_box_pay_now(''f0000000-0000-0000-0000-000000000a02'')', 'The host already got a Lucky Box on %(India time)') as ok;
select '1c the next day is a new box (expect 3000)' as check, (public.lucky_box_pay_now('f0000000-0000-0000-0000-000000000a03') ->> 'diamonds')::int as n;
-- 2. H2: the day of the box, not the day it was paid (both are paid right now)
select '2 23:00 start pays (expect 3000)' as check, (public.lucky_box_pay_now('f0000000-0000-0000-0000-000000000b01') ->> 'diamonds')::int as n;
select '2b 23:30 start opens after midnight = a different day: pays too (expect 3000)' as check, (public.lucky_box_pay_now('f0000000-0000-0000-0000-000000000b02') ->> 'diamonds')::int as n;
-- 3. H3: pulled back still counts for the day
select public.lucky_box_pay_now('f0000000-0000-0000-0000-000000000c01');
select public.lucky_box_pull_back((select id from public.wallet_ledger where reference_id = 'f0000000-0000-0000-0000-000000000c01' and note = 'lucky_box'));
select '3 after a pull back the day stays used (expect t)' as check,
       pg_temp.refused('select public.lucky_box_pay_now(''f0000000-0000-0000-0000-000000000c02'')', 'The host already got a Lucky Box on %') as ok;

-- 4. what the app is told: resting until the next IST midnight, only for the live that cannot open
select set_config('request.jwt.claim.sub', 'e9000000-0000-0000-0000-000000000009', false);
select '4 the 15:00 live of D-3 rests until D-2 00:00 IST (expect t)' as check,
       (public.lucky_box_status('f0000000-0000-0000-0000-000000000a02') ->> 'rest_until')::timestamptz = (((select today - 2 from d))::timestamp at time zone 'Asia/Kolkata') as ok;
select '4b the paid live is paid and not resting (expect t, null)' as check,
       (public.lucky_box_status('f0000000-0000-0000-0000-000000000a01') ->> 'paid')::boolean as paid,
       public.lucky_box_status('f0000000-0000-0000-0000-000000000a01') -> 'rest_until' as rest;
select '4c H2 second live is not resting (a different day) (expect null)' as check, public.lucky_box_status('f0000000-0000-0000-0000-000000000b02') -> 'rest_until' as rest;

-- 5. the Live history
select set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-000000000001', false);
select '5 history: the 15:00 live is Cooldown with no hours, the 10:00 live is Paid (expect cooldown, null, paid)' as check,
       (select result from public.lucky_box_history(7) where stream_id = 'f0000000-0000-0000-0000-000000000a02') as second,
       (select rest_hours from public.lucky_box_history(7) where stream_id = 'f0000000-0000-0000-0000-000000000a02') as hours,
       (select result from public.lucky_box_history(7) where stream_id = 'f0000000-0000-0000-0000-000000000a01') as first;
select '5b history: H3 second live is Cooldown because the pulled-back box still counts (expect cooldown)' as check,
       (select result from public.lucky_box_history(7) where stream_id = 'f0000000-0000-0000-0000-000000000c02') as n;

-- 6. hours mode is still there
update public.lucky_box_config set cooldown_mode = 'hours', cooldown_hours = 0;
select '6 hours mode with 0 = no cooldown: the same-day second live now pays (expect 3000)' as check,
       (public.lucky_box_pay_now('f0000000-0000-0000-0000-000000000a02') ->> 'diamonds')::int as n;
update public.lucky_box_config set cooldown_mode = 'ist_day', cooldown_hours = 24;

-- 7. the automatic payout follows the same rule: a host restarts after a drop. Both boxes fall on one IST day unless midnight sits between them.
insert into public.live_streams (id, host_id, title, status, mode, started_at, ended_at, last_heartbeat_at)
values ('f0000000-0000-0000-0000-000000000d01', 'a5000000-0000-0000-0000-000000000005', 'x', 'ended', 'video', now() - interval '3 hours', now() - interval '1 hour 40 minutes', now() - interval '1 hour 40 minutes');
insert into public.live_streams (id, host_id, title, status, mode, started_at, last_heartbeat_at)
values ('f0000000-0000-0000-0000-000000000d02', 'a5000000-0000-0000-0000-000000000005', 'y', 'live', 'video', now() - interval '1 hour', now());
-- the first live (box 2h20m ago) is only paid through the catch-up if it ended within 30 minutes; give it a normal win instead, as the cron would have
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
values ('a5000000-0000-0000-0000-000000000005', 'grant', 'diamonds', 3000, 'live_streams', 'f0000000-0000-0000-0000-000000000d01', 'lucky_box', now() - interval '2 hours 20 minutes');
select public.grant_lucky_box_rewards();
select '7 the restarted live is paid only when its box opens on a different IST day (expect t)' as check,
       ((select count(*) from public.wallet_ledger where reference_id = 'f0000000-0000-0000-0000-000000000d02' and note = 'lucky_box') = 1)
         = (public.lucky_box_day(now() - interval '1 hour' + interval '40 minutes') <> public.lucky_box_day(now() - interval '3 hours' + interval '40 minutes')) as ok;

-- 8. the helpers are internal
select '8 app users cannot call the helpers (expect f, f)' as check,
       has_function_privilege('authenticated', 'public.lucky_box_day(timestamptz)', 'execute') as day_fn,
       has_function_privilege('authenticated', 'public.lucky_box_day_taken(uuid,uuid,timestamptz,integer)', 'execute') as taken_fn;
select set_config('request.jwt.claim.sub', '', false);
