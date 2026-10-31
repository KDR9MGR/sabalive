-- Down script for supabase/migrations/20261031110000_brand_tone.sql. Applied BY HAND only. Drops the column; the panel stops offering the tone
-- (it only shows the control when the column is there) and the apps fall back to their default tone.
begin;
set local lock_timeout = '5s';
alter table public.app_config drop column if exists brand_tone;
commit;
