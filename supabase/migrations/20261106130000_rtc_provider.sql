-- Which real-time audio / video server a live room uses (owner, 2026-11-06: "bring the app also on MS cloud"; docs/STREAMING_SERVER_SWAP.md).
--
-- A live room is carried by ONE provider for its whole life: 'agora' (what every room has used so far, and the default) or 'livekit' (the hosted LiveKit server, "MS cloud" / LiveCore,
-- through the `livekit-token` function). The host's app sets it when it creates the room and every viewer's app reads it to know which one to join, so two phones on different builds
-- never end up in different places by accident.
--
-- Additive: ONE new column with a constant default, nothing reads it but the new app. An older app ignores it (it only ever joins Agora). NOTE FOR A PRODUCTION RELEASE: an older app
-- would still LIST a livekit room and fail to join it, so before any production build creates livekit rooms the old apps must be kept from seeing them (the way pk_ready keeps old
-- apps out of PK battles). Staging has no old apps, so nothing is needed for it.
-- Rollback: supabase/rollbacks/20261106130000_down.sql.
set local lock_timeout = '5s';

alter table public.live_streams add column if not exists rtc_provider text not null default 'agora';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'live_streams_rtc_provider_check') then
    alter table public.live_streams add constraint live_streams_rtc_provider_check check (rtc_provider in ('agora', 'livekit'));
  end if;
end $$;
