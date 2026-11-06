-- Down script for supabase/migrations/20261106130000_rtc_provider.sql
-- Applied BY HAND only. Removes the column that says which real-time server a live room uses. A room that is live on 'livekit' right now would be treated as an Agora room by every app
-- afterwards (nobody could hear or see the host): end such rooms first, or run this when none is live.
begin;
set local lock_timeout = '5s';
alter table public.live_streams drop constraint if exists live_streams_rtc_provider_check;
alter table public.live_streams drop column if exists rtc_provider;
commit;
