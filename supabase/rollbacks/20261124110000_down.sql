-- Undoes 20261124110000_diamond_reset_5am: the daily job goes back to 00:05 India time (18:35 UTC).
set local lock_timeout = '5s';
do $$
begin
  perform cron.unschedule('diamond-reset-auto');
exception when others then null;
end $$;
select cron.schedule('diamond-reset-auto', '35 18 * * *', $cron$ select public.run_diamond_reset_auto() $cron$);
