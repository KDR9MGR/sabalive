-- Down script for supabase/migrations/20261107120000_live_hearts.sql
-- Applied BY HAND only. Removes the shared heart counter: the function and the table (every live's heart total is DELETED). Nothing else is touched: like_count and stream_likes were never
-- changed. An app that already shows the shared hearts just shows its own taps again (it fails open when the row or the function is missing).
begin;
set local lock_timeout = '5s';
drop function if exists public.add_live_hearts(uuid, integer);
drop table if exists public.live_hearts;
commit;
