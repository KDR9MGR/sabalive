-- Down script for supabase/migrations/20261015100000_ban_hardening.sql
-- Applied BY HAND only. Removes the sign-up triggers FIRST (so sign-ups can never be affected), then the new functions and tables.
-- user_bans.user_id goes back to "on delete cascade" but is left nullable: bans whose account was deleted already stay as they are.
begin;
set local lock_timeout = '5s';
drop trigger if exists block_banned_identity_user on auth.users;
drop trigger if exists block_banned_identity_link on auth.identities;
drop trigger if exists user_bans_capture_signals on public.user_bans;
drop trigger if exists user_bans_release_signals on public.user_bans;
drop function if exists public.before_user_created_hook(jsonb);
drop function if exists public.admin_linked_accounts(uuid);
drop function if exists public.register_device_v2(text, text, text, text[]);
drop function if exists public.check_signup_access(text[], text, text, boolean);
drop function if exists public.device_ban_info(text[]);
drop function if exists public.block_banned_identity_user();
drop function if exists public.block_banned_identity_link();
drop function if exists public.release_ban_signals();
drop function if exists public.capture_ban_signals();
drop function if exists public.identity_ban_active(text, text);
drop function if exists public.normalize_identity(text, text);
drop table if exists public.banned_ips;
drop table if exists public.banned_identities;
alter table public.user_bans drop constraint if exists user_bans_user_id_fkey;
alter table public.user_bans add constraint user_bans_user_id_fkey foreign key (user_id) references public.profiles (id) on delete cascade;
commit;
