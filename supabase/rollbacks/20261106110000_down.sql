-- Down script for supabase/migrations/20261106110000_rankings_lifetime.sql
-- Applied BY HAND only. Removes the two Lifetime board functions. The boards store nothing, so there is nothing else to undo, and rankings_all_time() (older) stays.
-- An app that already shows the Lifetime tab would get an error on the Gifters and Agency boards of that tab until it is updated or the migration is applied again.
begin;
set local lock_timeout = '5s';
drop function if exists public.rankings_top_gifters_lifetime();
drop function if exists public.rankings_agencies_lifetime();
commit;
