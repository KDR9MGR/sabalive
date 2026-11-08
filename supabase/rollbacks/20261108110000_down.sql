-- Down script for supabase/migrations/20261108110000_vip_enabled_on.sql: switches VIP off again (the key is removed, which counts as off).
begin;
set local lock_timeout = '5s';
update public.app_config set feature_flags = feature_flags - 'vip_enabled' where id;
commit;
