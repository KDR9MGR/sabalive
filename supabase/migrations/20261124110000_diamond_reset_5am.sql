-- The automatic monthly diamond reset now runs at 05:00 India time (it ran at 00:05).
--
-- The owner asked for the reset "every 1st, in the morning, 5:00 AM". Only the schedule of the daily pg_cron job changes: 05:00 India time = 23:30 UTC the evening before, so the job
-- fires at 23:30 UTC every day and run_diamond_reset_auto() (unchanged) still acts only when today's India date is the chosen day (default the 1st), on the PREVIOUS month,
-- once per kind (an earlier reset of that month, by hand or automatic, is skipped). At 23:30 UTC on 31 Oct it is 05:00 on 1 Nov in India, so the day check passes.
-- It does not turn the automatic reset on or off and does not change the chosen day: those stay as the Super Admin / Master set them on the Diamond Reset page.
-- Rollback: supabase/rollbacks/20261124110000_down.sql (back to 00:05).
set local lock_timeout = '5s';

do $$
begin
  perform cron.unschedule('diamond-reset-auto');
exception when others then null;
end $$;
select cron.schedule('diamond-reset-auto', '30 23 * * *', $cron$ select public.run_diamond_reset_auto() $cron$);
