-- Down script for supabase/migrations/20261009110000_send_gift_to_all.sql
-- Applied BY HAND only. Apps that already call send_gift_to_all fall back to the old per-person loop only after an
-- update, so run this only if the function itself is misbehaving; the chat lines it wrote stay (they are plain rows).
begin;
set local lock_timeout = '5s';
drop function if exists public.send_gift_to_all(uuid, uuid);
alter table public.live_chat_messages drop column if exists to_all;
commit;
