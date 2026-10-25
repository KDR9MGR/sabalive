-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/gift_quantity_rollback_test.sql
-- Proves supabase/rollbacks/20261025100000_down.sql: both new functions and both chat columns are gone, the old gift functions still work, a second run is
-- harmless, and applying the migration again works.
insert into auth.users (id, email) values ('a8000000-0000-0000-0000-0000000000a1', 'rhost@x'), ('b8000000-0000-0000-0000-0000000000b2', 'rsender@x');
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at) values ('78787878-7878-7878-7878-787878787878', 'a8000000-0000-0000-0000-0000000000a1', 't', 'live', 'audio', now());
insert into public.gifts (id, name, emoji, price_coins) values ('89898989-8989-8989-8989-898989898989', 'Rose', 'R', 10);
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values ('b8000000-0000-0000-0000-0000000000b2', 'purchase', 'coins', 500, 'coin_purchases', 'funds');
select set_config('request.jwt.claim.sub', 'b8000000-0000-0000-0000-0000000000b2', false);
select '1 before: the new function works (expect 3)' as check, public.send_gift_v2('89898989-8989-8989-8989-898989898989', 'a8000000-0000-0000-0000-0000000000a1', '78787878-7878-7878-7878-787878787878', 3) as n;

\i supabase/rollbacks/20261025100000_down.sql

select '2 the functions are gone (expect 0)' as check, count(*) as n from pg_proc where proname in ('send_gift_v2', 'send_gift_to_all_v2');
select '2b the columns are gone (expect 0)' as check, count(*) as n from information_schema.columns
 where table_schema = 'public' and table_name = 'live_chat_messages' and column_name in ('gift_count', 'gift_receiver_ids');
select '2c the chat line of the earlier gift is still there (expect 1)' as check, count(*) as n from public.live_chat_messages where live_stream_id = '78787878-7878-7878-7878-787878787878' and kind = 'gift';
select '3 the old functions still work (expect t)' as check, (public.send_gift('89898989-8989-8989-8989-898989898989', 'a8000000-0000-0000-0000-0000000000a1', '78787878-7878-7878-7878-787878787878')).id is not null as ok;

\i supabase/rollbacks/20261025100000_down.sql
select '4 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'send_gift_v2';

\i supabase/migrations/20261025100000_gift_quantity_and_receivers.sql
select '5 re-applied: it works again (expect 2)' as check, public.send_gift_v2('89898989-8989-8989-8989-898989898989', 'a8000000-0000-0000-0000-0000000000a1', '78787878-7878-7878-7878-787878787878', 2) as n;
