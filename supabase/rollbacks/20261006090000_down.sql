-- Down script for supabase/migrations/20261006090000_app_release_controls.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Cannot be undone by this script: values already saved in the dropped columns (minimum / latest
-- versions, update message, store links). feature_flags is NOT dropped: it existed before the
-- migration (only its comment changed). The audit_logs rows 'app_release.changed' stay.
begin;
set local lock_timeout = '5s';      -- give up instead of queueing behind a long query and blocking everyone

drop trigger if exists app_config_release_guard on public.app_config;
drop function if exists public.guard_app_config_release_fields();
alter table public.app_config drop constraint if exists app_config_min_version_check;
alter table public.app_config
  drop column if exists min_android_version_code,
  drop column if exists latest_android_version_code,
  drop column if exists min_ios_build,
  drop column if exists latest_ios_build,
  drop column if exists update_message,
  drop column if exists android_store_url,
  drop column if exists ios_store_url;
comment on column public.app_config.feature_flags is null;

commit;
