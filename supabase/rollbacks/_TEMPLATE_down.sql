-- Down script for supabase/migrations/<VERSION>_<name>.sql
-- Applied BY HAND only, when that migration has to be undone. Replace the examples.
--
-- Cannot be undone by this script: <rows the migration repaired / data written since the push>
begin;
set local lock_timeout = '5s';      -- give up instead of queueing behind a long query and blocking everyone

-- a function that was replaced: put back its previous definition
--   create or replace function public.some_function(...) ... ;

-- a trigger or policy that was added
--   drop trigger if exists some_trigger on public.some_table;
--   drop policy if exists "Some policy" on public.some_table;

-- a column or table that was added (only if nothing depends on it yet)
--   alter table public.some_table drop column if exists some_column;

commit;
