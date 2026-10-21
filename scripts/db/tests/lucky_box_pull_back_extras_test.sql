-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/lucky_box_pull_back_extras_test.sql
-- Proves (20261021100000): per host per IST day the first box stays and every further one is pulled back; days are IST days (not UTC);
-- wins outside the window and wins already pulled back are left alone; a host who spent the diamonds is skipped, not overdrawn;
-- a second run finds nothing; only a Master / Super Admin with Lucky Box access can see or do it.
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-00000000000a', 'hostA@x'),
  ('a2000000-0000-0000-0000-00000000000b', 'hostB@x'),
  ('a3000000-0000-0000-0000-00000000000c', 'hostC@x'),
  ('a4000000-0000-0000-0000-00000000000d', 'hostD@x'),
  ('a5000000-0000-0000-0000-00000000000e', 'hostE@x'),
  ('a6000000-0000-0000-0000-00000000000f', 'hostF@x'),
  ('b1000000-0000-0000-0000-000000000001', 'master@x'),
  ('c1000000-0000-0000-0000-000000000002', 'plain@x');
insert into public.staff_roles (user_id, role) values ('b1000000-0000-0000-0000-000000000001', 'admin');

-- one helper to add a win at an IST time for a host
create or replace function pg_temp.win(p_host text, p_at text, p_id text) returns void language sql as $$
  insert into public.wallet_ledger (id, profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
  values (('d0000000-0000-0000-0000-' || p_id)::uuid, ('a' || position(p_host in 'abcdef') || '000000-0000-0000-0000-00000000000' || p_host)::uuid, 'grant', 'diamonds', 3000,
          'live_streams', ('e0000000-0000-0000-0000-' || p_id)::uuid, 'lucky_box', (p_at || '+05:30')::timestamptz);
$$;
-- A: three on 10 Oct and one on 11 Oct (expect 2 extras)
select pg_temp.win('a', '2026-10-10 10:00', '0000000000a1'); select pg_temp.win('a', '2026-10-10 12:00', '0000000000a2');
select pg_temp.win('a', '2026-10-10 15:00', '0000000000a3'); select pg_temp.win('a', '2026-10-11 09:00', '0000000000a4');
-- B: one a day (expect none)
select pg_temp.win('b', '2026-10-10 10:00', '0000000000b1'); select pg_temp.win('b', '2026-10-11 10:00', '0000000000b2'); select pg_temp.win('b', '2026-10-12 10:00', '0000000000b3');
-- C: two the same day, then the second one's diamonds are spent (expect skipped)
select pg_temp.win('c', '2026-10-12 08:00', '0000000000c1'); select pg_temp.win('c', '2026-10-12 20:00', '0000000000c2');
insert into public.wallet_ledger (profile_id, kind, currency, amount, note) values ('a3000000-0000-0000-0000-00000000000c', 'withdrawal', 'diamonds', -4000, 'spent');
-- D: two the same day, the first already pulled back by hand (expect none: one live box left)
select pg_temp.win('d', '2026-10-13 08:00', '0000000000d1'); select pg_temp.win('d', '2026-10-13 18:00', '0000000000d2');
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
  values ('a4000000-0000-0000-0000-00000000000d', 'grant_reversal', 'diamonds', -3000, 'wallet_ledger', 'd0000000-0000-0000-0000-0000000000d1', 'Pulled back: Lucky Box reward');
-- E: 23:30 IST and 00:30 IST next day: same UTC day, two IST days (expect none)
select pg_temp.win('e', '2026-10-14 23:30', '0000000000e1'); select pg_temp.win('e', '2026-10-15 00:30', '0000000000e2');
-- F: two on 8 Oct, before the window (expect none)
select pg_temp.win('f', '2026-10-08 10:00', '0000000000f1'); select pg_temp.win('f', '2026-10-08 12:00', '0000000000f2');

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

-- who may
select set_config('request.jwt.claim.sub', '', false);
select '1 signed out cannot preview (expect t)' as check, pg_temp.refused('select * from public.lucky_box_extra_wins(''2026-10-09'', ''2026-10-21'')', 'Only a Master%') as ok;
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000002', false);
select '1b a normal user cannot preview (expect t)' as check, pg_temp.refused('select * from public.lucky_box_extra_wins(''2026-10-09'', ''2026-10-21'')', 'Only a Master%') as ok;
select '1c a normal user cannot pull back (expect t)' as check, pg_temp.refused('select public.lucky_box_pull_back_extras(''2026-10-09'', ''2026-10-21'')', 'Only a Master%') as ok;

-- the preview
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);
select '2 preview lists A twice and C once and nobody else (expect A=2, C=1, total 3)' as check,
       count(*) filter (where host_username is not null) as total,
       count(*) filter (where host_id = 'a1000000-0000-0000-0000-00000000000a') as a, count(*) filter (where host_id = 'a3000000-0000-0000-0000-00000000000c') as c
  from public.lucky_box_extra_wins('2026-10-09', '2026-10-21');
select '2b C cannot cover its extra, A can (expect f, t)' as check,
       (select bool_and(can_cover) from public.lucky_box_extra_wins('2026-10-09', '2026-10-21') where host_id = 'a3000000-0000-0000-0000-00000000000c') as c_ok,
       (select bool_and(can_cover) from public.lucky_box_extra_wins('2026-10-09', '2026-10-21') where host_id = 'a1000000-0000-0000-0000-00000000000a') as a_ok;
select '2c a window longer than 40 days is refused (expect t)' as check, pg_temp.refused('select * from public.lucky_box_extra_wins(''2026-01-01'', ''2026-10-21'')', 'Pick a window of at most 40 days%') as ok;

-- the pull-back
create temp table r as select public.lucky_box_pull_back_extras('2026-10-09', '2026-10-21') as j;
select '3 pulled 2 wins = 6000 diamonds from 1 host, 1 skipped (expect 2, 6000, 1, 1)' as check,
       (j ->> 'pulled')::int as pulled, (j ->> 'diamonds')::bigint as diamonds, (j ->> 'hosts')::int as hosts, jsonb_array_length(j -> 'skipped') as skipped from r;
select '3b A kept two boxes (10:00 on 10 Oct and 09:00 on 11 Oct): 6000 diamonds (expect 6000)' as check, diamonds as n from public.wallets where profile_id = 'a1000000-0000-0000-0000-00000000000a';
select '3c the kept boxes are the first of each day (expect a1 and a4 not reversed, a2 and a3 reversed)' as check,
       (select string_agg(right(reference_id::text, 2), ',' order by reference_id) from public.wallet_ledger where kind = 'grant_reversal' and profile_id = 'a1000000-0000-0000-0000-00000000000a') as reversed;
select '3d C is untouched, not overdrawn (expect 2000)' as check, diamonds as n from public.wallets where profile_id = 'a3000000-0000-0000-0000-00000000000c';
select '3e B, D, E, F untouched (expect 9000, 3000, 6000, 6000)' as check,
       (select diamonds from public.wallets where profile_id = 'a2000000-0000-0000-0000-00000000000b') as b,
       (select diamonds from public.wallets where profile_id = 'a4000000-0000-0000-0000-00000000000d') as d,
       (select diamonds from public.wallets where profile_id = 'a5000000-0000-0000-0000-00000000000e') as e,
       (select diamonds from public.wallets where profile_id = 'a6000000-0000-0000-0000-00000000000f') as f;
select '3f reversal rows are tied to the win and not tagged lucky_box (expect 2 new + D1, t)' as check, count(*) as n,
       bool_and(note is distinct from 'lucky_box' and reference_table = 'wallet_ledger') as ok
  from public.wallet_ledger where kind = 'grant_reversal' and profile_id = 'a1000000-0000-0000-0000-00000000000a' or id = (select id from public.wallet_ledger where reference_id = 'd0000000-0000-0000-0000-0000000000d1');
select '3g audit: 2 per-win rows and 1 critical summary (expect 2, 1, critical)' as check,
       (select count(*) from public.audit_logs where action = 'lucky_box.pull_back') as per_win,
       (select count(*) from public.audit_logs where action = 'lucky_box.pull_back_extras') as summary,
       (select severity from public.audit_logs where action = 'lucky_box.pull_back_extras') as severity;

-- a second run finds nothing new (C is still skipped)
create temp table r2 as select public.lucky_box_pull_back_extras('2026-10-09', '2026-10-21') as j;
select '4 second run pulls nothing (expect 0, 0)' as check, (j ->> 'pulled')::int as pulled, (j ->> 'diamonds')::bigint as diamonds from r2;

select '5 anon cannot run either, signed-in users can (expect f, f, t, t)' as check,
       has_function_privilege('anon', 'public.lucky_box_extra_wins(date,date,text)', 'execute') as anon_preview,
       has_function_privilege('anon', 'public.lucky_box_pull_back_extras(date,date,text)', 'execute') as anon_run,
       has_function_privilege('authenticated', 'public.lucky_box_extra_wins(date,date,text)', 'execute') as authed_preview,
       has_function_privilege('authenticated', 'public.lucky_box_pull_back_extras(date,date,text)', 'execute') as authed_run;
