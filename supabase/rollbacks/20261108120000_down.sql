-- Down script for supabase/migrations/20261108120000_vip_enabled_off.sql: switches VIP on again.
begin;
set local lock_timeout = '5s';
update public.app_config set feature_flags = coalesce(feature_flags, '{}'::jsonb) || '{"vip_enabled": true}'::jsonb where id;
commit;
