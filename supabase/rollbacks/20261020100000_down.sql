-- Down script for supabase/migrations/20261020100000_pk_theme.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- The saved PK look is lost (the apps go back to their built-in colours, which is what they do while the value is empty). Nothing
-- else reads the column: the panel's PK look card shows a message while it is missing, and the apps fail open.
begin;
set local lock_timeout = '5s';

alter table public.app_config drop constraint if exists app_config_pk_theme_check;
alter table public.app_config drop column if exists pk_theme;

commit;
