-- Down script for supabase/migrations/20261025100000_gift_quantity_and_receivers.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Removes the two new gift functions and the two new chat columns (their values are lost: the chat lines keep their text). The apps then call the old
-- send_gift / send_gift_to_all (a new app falls back by itself when the new functions are missing), so a quantity of x10 is ten gifts again.
begin;
set local lock_timeout = '5s';

drop function if exists public.send_gift_to_all_v2(uuid, uuid, integer);
drop function if exists public.send_gift_v2(uuid, uuid, uuid, integer);
alter table public.live_chat_messages drop constraint if exists live_chat_messages_gift_count_check;
alter table public.live_chat_messages drop column if exists gift_receiver_ids;
alter table public.live_chat_messages drop column if exists gift_count;

commit;
