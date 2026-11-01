-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/revert_user_gifts_test.sql
-- Proves scripts/prod/revert_user_gifts_{plan,apply,undo}.sql with the REAL gift functions (send_gift_v2) on a scratch database: gifts are sent, the apply is run, and the whole
-- database (every wallet, every profile's xp and levels, every gift row, every ledger row, the live's total, the rankings, the stream diamonds) is then IDENTICAL to what it was
-- before those gifts; the undo brings it back identical to after them; gifts outside the window or between other people are untouched; and the apply refuses (changing nothing)
-- when a receiver no longer holds the diamonds, a ledger row is missing, the window is empty, the person is unknown or a monitoring account. Every line ends in ok = t.
set time zone 'UTC';
\set ON_ERROR_STOP off
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 't@x'),   -- T: the test user
  ('a2000000-0000-0000-0000-000000000002', 'a@x'),   -- A: sends gifts to T
  ('a3000000-0000-0000-0000-000000000003', 'r1@x'),  -- R1: receives from T and from A
  ('a4000000-0000-0000-0000-000000000004', 'r2@x'),  -- R2: receives from T
  ('a5000000-0000-0000-0000-000000000005', 'x@x'),   -- X, Y: have nothing to do with T
  ('a6000000-0000-0000-0000-000000000006', 'y@x'),
  ('a7000000-0000-0000-0000-000000000007', 'g@x');   -- a monitoring account
update public.profiles set display_id = 777001 where id = 'a1000000-0000-0000-0000-000000000001';
update public.profiles set display_id = 777002 where id = 'a2000000-0000-0000-0000-000000000002';
update public.profiles set display_id = 777003 where id = 'a3000000-0000-0000-0000-000000000003';
update public.profiles set display_id = 777004 where id = 'a4000000-0000-0000-0000-000000000004';
update public.profiles set display_id = 777005 where id = 'a5000000-0000-0000-0000-000000000005';
update public.profiles set display_id = 777006 where id = 'a6000000-0000-0000-0000-000000000006';
update public.profiles set display_id = 777007, is_ghost = true where id = 'a7000000-0000-0000-0000-000000000007';
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at)
values ('77777777-7777-7777-7777-777777777777', 'a3000000-0000-0000-0000-000000000003', 'revert test', 'live', 'audio', now());
insert into public.gifts (id, name, emoji, price_coins) values
  ('88888888-8888-8888-8888-888888888881', 'Rose', 'R', 10),
  ('88888888-8888-8888-8888-888888888882', 'Crown', 'C', 500000);
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values
  ('a1000000-0000-0000-0000-000000000001', 'grant', 'coins', 10000000, null, 'test funds'),
  ('a2000000-0000-0000-0000-000000000002', 'grant', 'coins', 10000000, null, 'test funds'),
  ('a5000000-0000-0000-0000-000000000005', 'grant', 'coins', 1000, null, 'test funds');

create temp table r (n serial, check_name text, ok boolean);
create function pg_temp.act_as(p text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p, false); $$;
create function pg_temp.gift(p_from text, p_gift text, p_to text, p_stream uuid, p_qty int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_from, false);
  perform public.send_gift_v2(p_gift::uuid, p_to::uuid, p_stream, p_qty);
end $$;
-- everything the undo must restore, as one comparable value
create function pg_temp.snap() returns jsonb language sql as $$
  select jsonb_build_object(
    'wallets', (select jsonb_agg(to_jsonb(w) - 'updated_at' order by profile_id) from public.wallets w),
    'profiles', (select jsonb_agg(jsonb_build_object('id', id, 'xp', xp, 'level', level, 'wx', wealth_xp, 'wl', wealth_level, 'cx', charm_xp, 'cl', charm_level) order by id) from public.profiles),
    'gifts', (select coalesce(jsonb_agg(to_jsonb(g) order by id), '[]'::jsonb) from public.gift_transactions g),
    'ledger', (select jsonb_agg(to_jsonb(l) order by id) from public.wallet_ledger l),
    'streams', (select jsonb_agg(jsonb_build_object('id', id, 't', gift_coin_total) order by id) from public.live_streams),
    'rank_hosts', (select coalesce(jsonb_agg(to_jsonb(x) order by profile_id), '[]'::jsonb) from public.rankings_monthly() x),
    'rank_gifters', (select coalesce(jsonb_agg(to_jsonb(x) order by profile_id), '[]'::jsonb) from public.rankings_top_gifters_monthly() x),
    'stream_diamonds', (select coalesce(jsonb_agg(to_jsonb(x) order by user_id), '[]'::jsonb) from public.stream_diamonds_today('77777777-7777-7777-7777-777777777777') x)
  )
$$;
-- wallet = sum of its ledger, for every person and currency (the invariant the undo must keep)
create function pg_temp.wallets_match_ledger() returns boolean language sql as $$
  select not exists (
    select 1 from public.wallets w
     where w.coins <> coalesce((select sum(amount) from public.wallet_ledger l where l.profile_id = w.profile_id and l.currency = 'coins'), 0)
        or w.diamonds <> coalesce((select sum(amount) from public.wallet_ledger l where l.profile_id = w.profile_id and l.currency = 'diamonds'), 0))
$$;


create function pg_temp.diff(a jsonb, b jsonb) returns text language sql as $$
  select coalesce(string_agg(k, ', '), 'none') from jsonb_object_keys(a) k where a -> k is distinct from b -> k
$$;

-- ---- OLDER gifts (to be left alone): sent now, then moved three days back
select pg_temp.gift('a1000000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888881', 'a3000000-0000-0000-0000-000000000003', '77777777-7777-7777-7777-777777777777', 2);
select pg_temp.gift('a2000000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888881', 'a1000000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', 1);
select pg_temp.gift('a5000000-0000-0000-0000-000000000005', '88888888-8888-8888-8888-888888888881', 'a6000000-0000-0000-0000-000000000006', '77777777-7777-7777-7777-777777777777', 3);
update public.gift_transactions set created_at = created_at - interval '3 days';
update public.wallet_ledger set created_at = created_at - interval '3 days' where kind in ('gift_sent', 'gift_received');

-- the window: from an hour ago to an hour ahead (UTC)
select to_char((now() - interval '1 hour') at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS') || '+00' as wfrom,
       to_char((now() + interval '1 hour') at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS') || '+00' as wto \gset
\setenv RG_FROM :wfrom
\setenv RG_TO :wto

-- two gifts inside the window that have nothing to do with T (they must still be there after the apply)
select pg_temp.gift('a2000000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888881', 'a3000000-0000-0000-0000-000000000003', '77777777-7777-7777-7777-777777777777', 2);  -- A -> R1 (not T)
select pg_temp.gift('a5000000-0000-0000-0000-000000000005', '88888888-8888-8888-8888-888888888881', 'a6000000-0000-0000-0000-000000000006', null, 1);                                  -- X -> Y

select pg_temp.snap() as s0 \gset
select pg_temp.wallets_match_ledger() as inv0 \gset
select wealth_level as wl0, charm_level as cl0, xp as xp0 from public.profiles where display_id = 777001 \gset

-- ---- THE BURST: the gifts of T inside the window (5 sent, 6 received, 1 of them to itself = 10 gifts)
select pg_temp.gift('a1000000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888881', 'a3000000-0000-0000-0000-000000000003', '77777777-7777-7777-7777-777777777777', 3);  -- T -> R1 x3 (30)
select pg_temp.gift('a1000000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888882', 'a1000000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', 1);  -- T -> T (500,000)
select pg_temp.gift('a1000000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888881', 'a4000000-0000-0000-0000-000000000004', null, 1);                                  -- T -> R2, no live (10)
select pg_temp.gift('a2000000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888882', 'a1000000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', 1);  -- A -> T (500,000)
select pg_temp.gift('a2000000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888881', 'a1000000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', 4);  -- A -> T x4 (40)

select pg_temp.snap() as s1 \gset
select wealth_level as wl1, charm_level as cl1, xp as xp1 from public.profiles where display_id = 777001 \gset
insert into r(check_name, ok) select '0 setup: the burst moved T''s wealth / charm levels and XP (so the levels check below means something)', :wl1 > :wl0 and :cl1 > :cl0 and :xp1 > :xp0;
insert into r(check_name, ok) select '0b setup: every wallet equals the sum of its ledger before anything is undone', :'inv0'::boolean;

-- ---- 1. the plan
\setenv RG_SQL scripts/prod/revert_user_gifts_plan.sql
\! python3 scripts/prod/revert_user_gifts_fill.py "$RG_SQL" 777001 "$RG_FROM" "$RG_TO" > /tmp/rg_plan.sql
\t on
\a
\o /tmp/rg_out.txt
\i /tmp/rg_plan.sql
\o
\t off
\a
\set plan `grep -a '^{' /tmp/rg_out.txt | head -1`
insert into r(check_name, ok) select '1 the plan counts the 10 gifts of T in the window (5 sent, 6 received, 1 to itself) = 1,000,080 coins, and finds a ledger row for each of them, with no blocker',
       (p ->> 'gifts')::int = 10 and (p ->> 'sent_by_target')::int = 5 and (p ->> 'received_by_target')::int = 6 and (p ->> 'self_gifts')::int = 1
       and (p ->> 'coins')::bigint = 30 + 500000 + 10 + 500000 + 40
       and (p ->> 'ledger_sent_matched')::int = 10 and (p ->> 'ledger_received_matched')::int = 10
       and jsonb_array_length(p -> 'blockers') = 0 and (p ->> 'streams')::int = 1
  from (select :'plan'::jsonb as p) q;
insert into r(check_name, ok) select '1b the plan lists the accounts that change: T, A, R1, R2 (not X, Y, not the monitoring account) and R1 gives back only the 30 from T',
       (select array_agg((a ->> 'user_id')::int order by (a ->> 'user_id')::int) from jsonb_array_elements(p -> 'accounts') a) = array[777001, 777002, 777003, 777004]
       and (select (a ->> 'diamonds_out')::int from jsonb_array_elements(p -> 'accounts') a where a ->> 'user_id' = '777003') = 30
  from (select :'plan'::jsonb as p) q;
insert into r(check_name, ok) select '1c the plan changed nothing', pg_temp.snap() = :'s1'::jsonb;

-- ---- 2. apply
\setenv RG_SQL scripts/prod/revert_user_gifts_apply.sql
\! python3 scripts/prod/revert_user_gifts_fill.py "$RG_SQL" 777001 "$RG_FROM" "$RG_TO" > /tmp/rg_apply.sql
\t on
\a
\o /tmp/rg_out.txt
\i /tmp/rg_apply.sql
\o
\t off
\a
\! grep -a '^{' /tmp/rg_out.txt | head -1 | jq -c .pack > /tmp/rg_pack.json
\set rep `grep -a '^{' /tmp/rg_out.txt | head -1 | jq -c 'del(.pack)'`
insert into r(check_name, ok) select '2 the apply reports 10 gifts undone and 20 ledger rows removed',
       (p ->> 'gifts_undone')::int = 10 and (p ->> 'ledger_rows_removed')::int = 20 and (p ->> 'accounts_changed')::int = 4
  from (select :'rep'::jsonb as p) q;
select 'after the apply these parts differ from before the burst: ' || pg_temp.diff(:'s0'::jsonb, pg_temp.snap()) as info;
insert into r(check_name, ok) select '2b the WHOLE database is identical to before the burst: every wallet, xp and level, gift row, ledger row, live total, ranking and stream diamond', pg_temp.snap() = :'s0'::jsonb;
insert into r(check_name, ok) select '2c every wallet still equals the sum of its ledger', pg_temp.wallets_match_ledger();
insert into r(check_name, ok) select '2d T''s levels are back where they were (' || :wl0 || ' / ' || :cl0 || ' / xp ' || :xp0 || ')',
       (select wealth_level = :wl0 and charm_level = :cl0 and xp = :xp0 from public.profiles where display_id = 777001);
insert into r(check_name, ok) select '2e the gifts that have nothing to do with T were not touched (A -> R1 x2 and X -> Y: 3 + 1 sent now, and the three older ones)',
       (select count(*) from public.gift_transactions where created_at > now() - interval '1 hour') = 3
       and (select count(*) from public.gift_transactions where created_at < now() - interval '1 day') = 6;
insert into r(check_name, ok) select '2f an audit row says what was done', exists (select 1 from public.audit_logs where action = 'gifts.reverted' and target like 'User ID 777001: 10 gifts%' and severity = 'critical');
\setenv RG_SQL scripts/prod/revert_user_gifts_plan.sql
\! python3 scripts/prod/revert_user_gifts_fill.py "$RG_SQL" 777001 "$RG_FROM" "$RG_TO" > /tmp/rg_plan.sql
\t on
\a
\o /tmp/rg_out.txt
\i /tmp/rg_plan.sql
\o
\t off
\a
\set plan `grep -a '^{' /tmp/rg_out.txt | head -1`
insert into r(check_name, ok) select '2g running the plan again finds nothing left to undo', (p ->> 'gifts')::int = 0 and p -> 'blockers' = '["no gifts in this window"]'::jsonb from (select :'plan'::jsonb as p) q;

-- ---- 3. undo brings it all back, identically
\setenv RG_SQL scripts/prod/revert_user_gifts_undo.sql
\! python3 scripts/prod/revert_user_gifts_fill.py "$RG_SQL" 777001 "$RG_FROM" "$RG_TO" /tmp/rg_pack.json > /tmp/rg_undo.sql
\t on
\a
\o /tmp/rg_out.txt
\i /tmp/rg_undo.sql
\o
\t off
\a
insert into r(check_name, ok) select '3 after the undo the whole database is identical to after the burst', pg_temp.snap() = :'s1'::jsonb;
insert into r(check_name, ok) select '3b wallets still equal their ledgers', pg_temp.wallets_match_ledger();
-- a second undo is refused and changes nothing
\i /tmp/rg_undo.sql
rollback;
insert into r(check_name, ok) select '3c a second undo is refused (the gifts are already back) and changes nothing', pg_temp.snap() = :'s1'::jsonb;

-- ---- 4. refusals: each one changes nothing
-- 4a. a receiver no longer holds the diamonds (an admin pulled them back): R1 holds 70, needs 30, so take 60 away
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
  values ('a3000000-0000-0000-0000-000000000003', 'grant_reversal', 'diamonds', -60, null, 'test pull back');
select pg_temp.snap() as s4 \gset
\setenv RG_SQL scripts/prod/revert_user_gifts_apply.sql
\! python3 scripts/prod/revert_user_gifts_fill.py "$RG_SQL" 777001 "$RG_FROM" "$RG_TO" > /tmp/rg_apply.sql
\i /tmp/rg_apply.sql
rollback;
insert into r(check_name, ok) select '4 a receiver that no longer holds the diamonds: the apply is refused and nothing changes', pg_temp.snap() = :'s4'::jsonb;
\setenv RG_SQL scripts/prod/revert_user_gifts_plan.sql
\! python3 scripts/prod/revert_user_gifts_fill.py "$RG_SQL" 777001 "$RG_FROM" "$RG_TO" > /tmp/rg_plan.sql
\t on
\a
\o /tmp/rg_out.txt
\i /tmp/rg_plan.sql
\o
\t off
\a
\set plan `grep -a '^{' /tmp/rg_out.txt | head -1`
insert into r(check_name, ok) select '4b the plan names that account as a blocker', (select count(*) from jsonb_array_elements_text(:'plan'::jsonb -> 'blockers') b where b like 'account 777003 holds %') = 1;
-- put R1's diamonds back
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
  values ('a3000000-0000-0000-0000-000000000003', 'grant', 'diamonds', 60, null, 'test restore');

-- 4c. a ledger row that no longer matches (a gift_received row of T is gone)
delete from public.wallet_ledger where id = (select id from public.wallet_ledger where profile_id = 'a1000000-0000-0000-0000-000000000001' and kind = 'gift_received' and amount = 500000 order by id limit 1);
select pg_temp.snap() as s5 \gset
\setenv RG_SQL scripts/prod/revert_user_gifts_apply.sql
\! python3 scripts/prod/revert_user_gifts_fill.py "$RG_SQL" 777001 "$RG_FROM" "$RG_TO" > /tmp/rg_apply.sql
\i /tmp/rg_apply.sql
rollback;
insert into r(check_name, ok) select '4c a ledger row that does not match a gift: the apply is refused and nothing changes', pg_temp.snap() = :'s5'::jsonb;

-- 4d. an empty window, an unknown User ID and a monitoring account
\! python3 scripts/prod/revert_user_gifts_fill.py scripts/prod/revert_user_gifts_apply.sql 777001 "2020-01-01 00:00:00+00" "2020-01-02 00:00:00+00" > /tmp/rg_apply.sql
\i /tmp/rg_apply.sql
rollback;
\! python3 scripts/prod/revert_user_gifts_fill.py scripts/prod/revert_user_gifts_apply.sql 999999 "$RG_FROM" "$RG_TO" > /tmp/rg_apply.sql
\i /tmp/rg_apply.sql
rollback;
\! python3 scripts/prod/revert_user_gifts_fill.py scripts/prod/revert_user_gifts_apply.sql 777007 "$RG_FROM" "$RG_TO" > /tmp/rg_apply.sql
\i /tmp/rg_apply.sql
rollback;
insert into r(check_name, ok) select '4d an empty window, an unknown User ID and a monitoring account are all refused and nothing changes', pg_temp.snap() = :'s5'::jsonb;

-- 4e. the helper refuses a bad User ID or window before any SQL is built
\set e1 `python3 scripts/prod/revert_user_gifts_fill.py scripts/prod/revert_user_gifts_plan.sql "777001; drop table x" "$RG_FROM" "$RG_TO" >/dev/null 2>&1; echo $?`
\set e2 `python3 scripts/prod/revert_user_gifts_fill.py scripts/prod/revert_user_gifts_plan.sql 777001 "tomorrow" "$RG_TO" >/dev/null 2>&1; echo $?`
insert into r(check_name, ok) select '4e the fill helper refuses a bad User ID and a bad window (non-zero exit)', :e1 <> 0 and :e2 <> 0;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
