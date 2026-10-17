-- Down script for supabase/migrations/20261017110000_pk_layer_functions.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Cannot be undone by this script: battles already created by these functions keep their rows (they are ordinary pk_battles
-- rows with source set; the legacy functions can still finish or cancel them), and the queue rows (pk_match_queue is dropped by
-- the foundations down script).
begin;
set local lock_timeout = '5s';

-- stop the sweep first, so nothing runs while the function goes
do $outer$
begin
  if exists (select 1 from cron.job where jobname = 'pk-forfeit-sweep') then
    perform cron.unschedule('pk-forfeit-sweep');
  end if;
end;
$outer$;

drop function if exists public.pk_forfeit_sweep();
drop function if exists public.pk_begin_v2(uuid);
drop function if exists public.pk_random_leave(uuid);
drop function if exists public.pk_random_join(uuid);
drop function if exists public.pk_eligible_following(uuid);
drop function if exists public.pk_invite_v2(uuid, uuid, integer);
drop function if exists public.pk_set_ready(uuid, boolean);
drop function if exists public.pk_hosts_blocked(uuid, uuid);
drop function if exists public.pk_stream_busy(uuid);

commit;
