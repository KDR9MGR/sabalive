-- Down script for supabase/migrations/20261017100000_pk_layer_foundations.sql
-- Run 20261017110000_down.sql FIRST (its functions read these columns and tables).
-- Applied BY HAND only, when that migration has to be undone.
--
-- Cannot be undone by this script: the VALUES in the dropped columns (duration_seconds, kind, source, end_reason, pk_ready)
-- and the contents of pk_config / pk_match_queue. Legacy battles do not use any of them.
begin;
set local lock_timeout = '5s';

drop table if exists public.pk_match_queue;
drop table if exists public.pk_config;
alter table public.live_streams drop column if exists pk_ready;
alter table public.pk_battles
  drop column if exists end_reason,
  drop column if exists source,
  drop column if exists kind,
  drop column if exists duration_seconds;

commit;
