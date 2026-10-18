-- Down script for supabase/migrations/20261018100000_pk_admin_rules.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Cannot be undone by this script: the pk_config values changed through the function stay as they are, and the audit log lines stay.
begin;
set local lock_timeout = '5s';

drop function if exists public.admin_set_pk_config(integer[], integer, integer, integer, integer);

commit;
