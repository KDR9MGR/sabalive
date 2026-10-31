-- The panel's Site / Branding "Background tone" (Deep / Rich / Soft): how much colour the consumer app's backgrounds carry, 2026-10-31.
-- Deep = the brand hue turned down to almost black (the old look), Rich = clearly coloured (the new default), Soft = the lightest the app's fixed light text can sit on.
-- One new column on the app_config singleton; it is written by the panel through the existing app_config update (only Super Admin can edit that row) and read by the app
-- with its OWN query, so an app on a database without it (or this database with an older app) is unaffected: an old app never reads it and keeps its old look.
-- Additive. Rollback: supabase/rollbacks/20261031110000_down.sql. Test: scripts/db/tests/brand_tone_test.sql.
set local lock_timeout = '5s';
alter table public.app_config
  add column if not exists brand_tone text not null default 'rich' check (brand_tone in ('deep', 'rich', 'soft'));
