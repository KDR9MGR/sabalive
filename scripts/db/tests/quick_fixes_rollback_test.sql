-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/quick_fixes_rollback_test.sql
-- Proves supabase/rollbacks/20261026140000_down.sql: send_gift_to_all_v3 is gone and v2 still works, the diamond reset reads run_payroll again, set_staff_permissions no
-- longer knows reset_diamonds, gifts already sent stay, a second run is harmless, and the migration applies again.
insert into auth.users (id, email) values
  ('a7000000-0000-0000-0000-000000000001', 'host@x'), ('d7000000-0000-0000-0000-000000000004', 'sender@x'),
  ('a1000000-0000-0000-0000-0000000000a1', 'master@x'), ('e1000000-0000-0000-0000-0000000000e6', 'super@x');
insert into public.staff_roles (user_id, role) values ('a1000000-0000-0000-0000-0000000000a1', 'admin'), ('e1000000-0000-0000-0000-0000000000e6', 'super_admin');
insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at) values ('77777777-7777-7777-7777-777777777777', 'a7000000-0000-0000-0000-000000000001', 't', 'live', 'audio', now());
insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at) values
  ('77777777-7777-7777-7777-777777777777', 1, 'a7000000-0000-0000-0000-000000000001', now()), ('77777777-7777-7777-7777-777777777777', 2, 'd7000000-0000-0000-0000-000000000004', now());
insert into public.gifts (id, name, emoji, price_coins) values ('98989898-9898-9898-9898-989898989898', 'Rose7', 'R', 10);
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values ('d7000000-0000-0000-0000-000000000004', 'purchase', 'coins', 1000, 'coin_purchases', 'funds');
select set_config('request.jwt.claim.sub', 'd7000000-0000-0000-0000-000000000004', false);
create temp table before as select public.send_gift_to_all_v3('98989898-9898-9898-9898-989898989898', '77777777-7777-7777-7777-777777777777', 1) as n;
select '1 before: v3 reaches 2 people, the sender included (expect 2)' as check, n from before;

\i supabase/rollbacks/20261026140000_down.sql

select '2 v3 is gone (expect 0)' as check, count(*) as n from pg_proc where proname = 'send_gift_to_all_v3';
select '3 v2 still works and leaves the sender out (expect 1)' as check, public.send_gift_to_all_v2('98989898-9898-9898-9898-989898989898', '77777777-7777-7777-7777-777777777777', 1) as n;
select '4 the gift already sent stays (expect 3: host and sender from the first send, the host from the v2 call)' as check, count(*) as n
  from public.gift_transactions where sender_id = 'd7000000-0000-0000-0000-000000000004' and receiver_id in ('a7000000-0000-0000-0000-000000000001', 'd7000000-0000-0000-0000-000000000004');
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e6', false);
do $$ begin
  perform public.set_staff_permissions('a1000000-0000-0000-0000-0000000000a1', '{"reset_diamonds": false}'::jsonb);
  raise exception 'expected Unknown permission';
exception when others then
  if sqlerrm not like 'Unknown permission%' then raise; end if;
end $$;
select '5 set_staff_permissions no longer knows reset_diamonds (expect t)' as check, true as ok;
select '6 the diamond reset reads run_payroll again: a Master passes by default (expect t)' as check,
  (select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-0000000000a1', false)) is not null and (public.admin_diamond_reset_preview('2026-01') is not null) as ok;

\i supabase/rollbacks/20261026140000_down.sql
select '7 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'send_gift_to_all_v3';

\i supabase/migrations/20261026140000_quick_fixes_gift_all_self_permission.sql
select set_config('request.jwt.claim.sub', 'd7000000-0000-0000-0000-000000000004', false);
select '8 re-applied: v3 works again (expect 2)' as check, public.send_gift_to_all_v3('98989898-9898-9898-9898-989898989898', '77777777-7777-7777-7777-777777777777', 1) as n;
