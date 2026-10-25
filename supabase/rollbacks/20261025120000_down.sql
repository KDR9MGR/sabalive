-- Down script for supabase/migrations/20261025120000_ban_custom_end_and_reason.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Removes ban_user_v2, check_login_access_v2 and user_bans.reason_visible. Bans already placed keep their end dates (24 hour and custom bans stay in
-- force until they end). The panel falls back to ban_user (7 days, 30 days, permanent) and the app to the plain "This account has been banned." text.
-- The "visible to the user" flags are lost; the reasons themselves stay in user_bans.reason.
begin;
set local lock_timeout = '5s';

drop function if exists public.check_login_access_v2(text[], text, text);
drop function if exists public.ban_user_v2(uuid, text[], text, text, timestamptz);
alter table public.user_bans drop column if exists reason_visible;

commit;
