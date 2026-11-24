-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/lucky_box_by_month_test.sql
-- Proves (20261124120000): the month is cut in INDIA time (a win one minute before 1 Nov 00:00 IST is October, at 00:00 IST it is November), the people list adds up wins, diamonds won and
-- diamonds pulled back per person, the rewards list shows every win with its exact time newest first and marks a pulled-back one, one person can be asked for by app User ID, a bad
-- month is refused, a Master and a Super Admin can read it while a Country Admin without Lucky Box access and an ordinary account cannot, and the rollback runs and the migration applies again.
insert into auth.users (id, email, raw_user_meta_data) select v.id::uuid, v.email, jsonb_build_object('username', 'usr_' || split_part(v.email, '@', 1), 'name', initcap(split_part(v.email, '@', 1)))
  from (values ('00000000-0000-0000-0000-000000000001', 's0@x'), ('00000000-0000-0000-0000-000000000002', 'm0@x'), ('00000000-0000-0000-0000-000000000003', 'c1@x'),
               ('00000000-0000-0000-0000-000000000011', 'h1@x'), ('00000000-0000-0000-0000-000000000012', 'h2@x'), ('00000000-0000-0000-0000-000000000013', 'h3@x'),
               ('00000000-0000-0000-0000-000000000021', 'u1@x')) v(id, email);
insert into public.staff_roles (user_id, role) values ('00000000-0000-0000-0000-000000000001', 'super_admin'), ('00000000-0000-0000-0000-000000000002', 'admin'), ('00000000-0000-0000-0000-000000000003', 'country_admin');

-- the wins (what the payout job writes: a 'grant' of diamonds with note 'lucky_box', pointing at the live)
insert into public.wallet_ledger (id, profile_id, kind, currency, amount, reference_table, reference_id, note, created_at) values
  ('d0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000011', 'grant', 'diamonds', 3000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-10-05 10:00:00+00'),
  ('d0000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000011', 'grant', 'diamonds', 3000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-10-31 18:29:00+00'),   -- 23:59 IST on 31 Oct
  ('d0000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000011', 'grant', 'diamonds', 3000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-10-31 18:30:00+00'),   -- 00:00 IST on 1 Nov
  ('d0000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000012', 'grant', 'diamonds', 2000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-10-15 12:00:00+00'),
  ('d0000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000012', 'grant', 'diamonds', 2000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-10-20 12:00:00+00'),   -- pulled back below
  ('d0000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000013', 'grant', 'diamonds', 1000, 'live_streams', gen_random_uuid(), 'lucky_box', '2026-09-30 18:29:00+00'),   -- 23:59 IST on 30 Sep: September
  ('d0000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000021', 'grant', 'diamonds', 500, 'live_streams', gen_random_uuid(), 'other', '2026-10-10 10:00:00+00');         -- not a Lucky Box win
-- the pull back of win 5, done in November (a month later): it must still mark the October win
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note, created_at)
  values ('00000000-0000-0000-0000-000000000012', 'grant_reversal', 'diamonds', -2000, 'wallet_ledger', 'd0000000-0000-0000-0000-000000000005', 'Lucky Box pulled back', '2026-11-03 09:00:00+00');
create table public.t_ids as select name, display_id from public.profiles;
grant all on public.t_ids to authenticated;
create function public.t_who(p_sub text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_sub, false) $$;
grant execute on function public.t_who(text) to authenticated;

select public.t_who('00000000-0000-0000-0000-000000000002');   -- Master
set role authenticated;
select '1 October people (expect H1 2 wins 6000, H2 2 wins 4000 of which 2000 pulled back; nobody else)' as check, name, wins, diamonds, pulled_back_diamonds
  from public.lucky_box_month_people('2026-10') order by diamonds desc;
select '2 November people (expect H1 1 win 3000, the boundary win at 00:00 IST)' as check, name, wins, diamonds, to_char(first_win at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') as first_ist
  from public.lucky_box_month_people('2026-11');
select '3 September people (expect H3 1 win)' as check, name, wins, diamonds from public.lucky_box_month_people('2026-09');
select '4 October rewards, newest first with exact India time (expect 4 rows: 31 Oct 23:59, 20 Oct 17:30 pulled back, 15 Oct 17:30, 5 Oct 15:30)' as check,
       name, diamonds, to_char(won_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') as ist, pulled_back
  from public.lucky_box_month_rewards('2026-10');
select '5 one person by app User ID (expect only H2, 2 rows)' as check, name, count(*) over () as n
  from public.lucky_box_month_rewards('2026-10', (select display_id from public.t_ids where name = 'H2'));
select '6 an empty month is an empty list (expect 0)' as check, count(*) as n from public.lucky_box_month_rewards('2025-01');
reset role;

-- refusals
create function public.t_refused(p_sql text, p_like text) returns boolean language plpgsql as $$ begin execute p_sql; return false; exception when others then return sqlerrm like p_like; end $$;
grant execute on function public.t_refused(text, text) to authenticated;
select public.t_who('00000000-0000-0000-0000-000000000002');
set role authenticated;
select '7 a bad month is refused (expect t, t, t)' as check,
  public.t_refused('select * from public.lucky_box_month_people(''abc'')', 'Pick a month%') as a,
  public.t_refused('select * from public.lucky_box_month_people(''2026-13'')', 'Pick a month%') as b,
  public.t_refused('select * from public.lucky_box_month_rewards(null)', 'Pick a month%') as c;
select public.t_who('00000000-0000-0000-0000-000000000003');   -- a Country Admin with no Lucky Box access
select '8 a Country Admin without Lucky Box access is refused (expect t, t)' as check,
  public.t_refused('select * from public.lucky_box_month_people(''2026-10'')', 'Only a Master or Super Admin%') as people,
  public.t_refused('select * from public.lucky_box_month_rewards(''2026-10'')', 'Only a Master or Super Admin%') as rewards;
select public.t_who('00000000-0000-0000-0000-000000000021');   -- an ordinary account
select '9 an ordinary account is refused (expect t)' as check, public.t_refused('select * from public.lucky_box_month_rewards(''2026-10'')', 'Only a Master or Super Admin%') as ok;
select public.t_who('00000000-0000-0000-0000-000000000001');   -- Super Admin
select '10 a Super Admin can read it (expect 2 people in October)' as check, count(*) as n from public.lucky_box_month_people('2026-10') where wins > 0;
reset role;

\i supabase/rollbacks/20261124120000_down.sql
select '11 after the rollback the functions are gone (expect 0)' as check, count(*) as n from pg_proc where proname in ('lucky_box_month_people', 'lucky_box_month_rewards');
\i supabase/migrations/20261124120000_lucky_box_by_month.sql
select '12 the migration applies again (expect 2)' as check, count(*) as n from pg_proc where proname in ('lucky_box_month_people', 'lucky_box_month_rewards');
