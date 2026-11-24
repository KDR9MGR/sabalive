-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/diamond_reset_5am_test.sql
-- Proves (20261124110000): the job time 23:30 UTC is 05:00 on the 1st in India, and run_diamond_reset_auto() (unchanged) acts then: with the switch on and the day = 1 it resets the month
-- before (October), a second call changes nothing more, the same instant on any other day does nothing, and the rollback script runs and the migration applies again.
insert into auth.users (id, email, raw_user_meta_data) select v.id::uuid, v.email, jsonb_build_object('username', 'usr_' || split_part(v.email, '@', 1))
  from (values ('00000000-0000-0000-0000-000000000001', 's0@x'), ('00000000-0000-0000-0000-000000000002', 'h1@x')) v(id, email);
insert into public.staff_roles (user_id, role) values ('00000000-0000-0000-0000-000000000001', 'super_admin');
-- a gift in October (India time) so the month has diamonds to reset, and a balance to take them from
update public.wallets set diamonds = 500 where profile_id = '00000000-0000-0000-0000-000000000002';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
update public.diamond_reset_settings set enabled = true, reset_gift = true, reset_reward = false, run_day = 1 where id;

select '1 the job instant is 05:00 on the 1st in India (expect 2026-11-01 05:00:00)' as check, ('2026-10-31 23:30:00+00'::timestamptz at time zone 'Asia/Kolkata')::text as ist;
select '2 the same instant a day later is the 2nd, not the day (expect f)' as check, (extract(day from ('2026-11-01 23:30:00+00'::timestamptz at time zone 'Asia/Kolkata')) = 1) as is_first;
select '3 any other day does nothing (expect ran=false, not the day)' as check, public.run_diamond_reset_auto('2026-11-01 23:30:00+00') ->> 'why' as why;
select '4 05:00 India time on the 1st runs and names October (expect true, 2026-10)' as check,
       (r ->> 'ran') as ran, (r ->> 'period') as period from (select public.run_diamond_reset_auto('2026-10-31 23:30:00+00') as r) x;
select '5 a second call the same morning changes nothing more (expect 1 run for 2026-10 gift)' as check,
       (select count(*) from public.diamond_reset_runs where period = '2026-10' and source = 'gift' and undone_at is null) as runs
  from (select public.run_diamond_reset_auto('2026-10-31 23:30:00+00')) y;

\i supabase/rollbacks/20261124110000_down.sql
select '6 the rollback ran (reached here)' as check;
\i supabase/migrations/20261124110000_diamond_reset_5am.sql
select '7 the migration applies again (reached here)' as check;
