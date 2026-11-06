-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/rankings_lifetime_test.sql
-- Proves (20261106110000): the Lifetime boards count EVERY gift ever sent, including ones from years ago that the monthly boards leave out, with the same rules as the other
-- boards (hosts = diamonds received, gifters = coins spent, agencies = all of an agency's hosts added together), best first, the old Monthly boards are unchanged, and only
-- signed-in app users (not anon) can read the new functions. Every line ends in ok = t; the last line says ALL PASSED or how many failed.
set time zone 'UTC';
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'send1@x'), ('a2000000-0000-0000-0000-000000000002', 'send2@x'),
  ('b1000000-0000-0000-0000-000000000001', 'host1@x'), ('b2000000-0000-0000-0000-000000000002', 'host2@x'), ('b3000000-0000-0000-0000-000000000003', 'host3@x');
insert into public.agencies (id, name) values
  ('c1000000-0000-0000-0000-000000000001', 'Agency One'), ('c2000000-0000-0000-0000-000000000002', 'Agency Two');
insert into public.host_profiles (profile_id, agency_id, status) values
  ('b1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'active'),
  ('b2000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', 'active'),
  ('b3000000-0000-0000-0000-000000000003', 'c2000000-0000-0000-0000-000000000002', 'active');
insert into public.gifts (id, name, emoji, price_coins) values ('d0000000-0000-0000-0000-000000000001', 'Rose', 'r', 1);

-- sender 1 -> host 1: 1000 two years ago + 300 now; sender 1 -> host 2: 50 now; sender 2 -> host 3: 700 a year ago (so Agency Two only has old gifts)
insert into public.gift_transactions (sender_id, receiver_id, gift_id, coins, created_at) values
  ('a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 1000, now() - interval '2 years'),
  ('a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 300, now()),
  ('a1000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000001', 50, now()),
  ('a2000000-0000-0000-0000-000000000002', 'b3000000-0000-0000-0000-000000000003', 'd0000000-0000-0000-0000-000000000001', 700, now() - interval '1 year');

create temp table r (n serial, check_name text, ok boolean);

insert into r(check_name, ok) select '1 hosts lifetime (rankings_all_time) counts the old gift too: host 1 = 1300, host 3 = 700, host 2 = 50',
       (select score from public.rankings_all_time() where profile_id = 'b1000000-0000-0000-0000-000000000001') = 1300
       and (select score from public.rankings_all_time() where profile_id = 'b3000000-0000-0000-0000-000000000003') = 700
       and (select score from public.rankings_all_time() where profile_id = 'b2000000-0000-0000-0000-000000000002') = 50;
insert into r(check_name, ok) select '2 gifters lifetime: sender 1 spent 1350 (1000 + 300 + 50), sender 2 spent 700',
       (select score from public.rankings_top_gifters_lifetime() where profile_id = 'a1000000-0000-0000-0000-000000000001') = 1350
       and (select score from public.rankings_top_gifters_lifetime() where profile_id = 'a2000000-0000-0000-0000-000000000002') = 700;
insert into r(check_name, ok) select '3 agencies lifetime: Agency One = host 1 + host 2 (1350), Agency Two = 700 (only an old gift) and has a name',
       (select score from public.rankings_agencies_lifetime() where agency_id = 'c1000000-0000-0000-0000-000000000001') = 1350
       and (select score from public.rankings_agencies_lifetime() where agency_id = 'c2000000-0000-0000-0000-000000000002') = 700
       and (select agency_name from public.rankings_agencies_lifetime() where agency_id = 'c2000000-0000-0000-0000-000000000002') = 'Agency Two';
insert into r(check_name, ok) select '4 best first on all three boards',
       (select array_agg(score order by ord) = array(select score from public.rankings_all_time() order by score desc) from (select score, row_number() over () ord from public.rankings_all_time()) t)
       and (select profile_id from public.rankings_top_gifters_lifetime() limit 1) = 'a1000000-0000-0000-0000-000000000001'
       and (select agency_id from public.rankings_agencies_lifetime() limit 1) = 'c1000000-0000-0000-0000-000000000001';
insert into r(check_name, ok) select '5 the old gift is NOT in the Monthly boards (unchanged): host 1 month = 300, sender 1 month = 350, Agency Two is absent from the monthly agency board',
       (select score from public.rankings_monthly() where profile_id = 'b1000000-0000-0000-0000-000000000001') = 300
       and (select score from public.rankings_top_gifters_monthly() where profile_id = 'a1000000-0000-0000-0000-000000000001') = 350
       and not exists (select 1 from public.rankings_agencies_monthly() where agency_id = 'c2000000-0000-0000-0000-000000000002');
insert into r(check_name, ok) select '6 signed-in app users can read the new boards, anon and the public cannot',
       has_function_privilege('authenticated', 'public.rankings_top_gifters_lifetime()', 'execute')
       and has_function_privilege('authenticated', 'public.rankings_agencies_lifetime()', 'execute')
       and not has_function_privilege('anon', 'public.rankings_top_gifters_lifetime()', 'execute')
       and not has_function_privilege('anon', 'public.rankings_agencies_lifetime()', 'execute');
insert into r(check_name, ok) select '7 a board never returns more than 200 rows',
       (select count(*) from public.rankings_top_gifters_lifetime()) <= 200 and (select count(*) from public.rankings_agencies_lifetime()) <= 200;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
