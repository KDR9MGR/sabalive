-- Down script for supabase/migrations/20261106100000_admin_end_stream.sql (Live Monitor "Kill stream")
-- Applied BY HAND only, when that migration has to be undone.
--
-- Cannot be undone by this script: lives that were ended with it stay ended (a live that is over cannot be restarted),
-- and its `live.killed` rows stay in audit_logs. The panel's Kill stream button then answers "function not found" (it says so in words); nothing else is affected.
begin;
set local lock_timeout = '5s';

drop function if exists public.admin_end_stream(uuid);

commit;
