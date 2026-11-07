-- Down script for supabase/migrations/20261107110000_gift_notices.sql
-- Applied BY HAND only. Removes the gift-notice feed: the trigger on live_chat_messages, its two functions and the table (the few recent notice rows are deleted; chat rows, gifts and
-- wallets are not touched). An app that already listens for the feed just stops hearing about big gifts (it fails open to "nothing to show").
begin;
set local lock_timeout = '5s';
drop trigger if exists live_chat_messages_gift_notice on public.live_chat_messages;
drop function if exists public._gift_notice_after_chat();
drop table if exists public.gift_notices;
drop function if exists public.gift_notice_min_coins();
commit;
