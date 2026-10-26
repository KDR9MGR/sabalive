-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/diamond_reset_rollback_test.sql
-- Proves supabase/rollbacks/20261026120000_down.sql: every diamond-reset object is gone, the negative ledger rows a reset wrote stay (history), the wallets stay as they
-- were after the reset, a second run is harmless, and the migration applies again.
insert into auth.users (id, email) values ('b1000000-0000-0000-0000-0000000000b1', 'h1@x'), ('e1000000-0000-0000-0000-0000000000e6', 'super@x');
insert into public.staff_roles (user_id, role) values ('e1000000-0000-0000-0000-0000000000e6', 'super_admin');
insert into public.wallet_ledger (profile_id, kind, currency, amount, created_at) values ('b1000000-0000-0000-0000-0000000000b1', 'gift_received', 'diamonds', 1000, '2026-09-10 12:00+00');
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e6', false);
select '1 before: a reset works (expect 1 wallet, 1000)' as check, (r -> 0 ->> 'wallets')::int as wallets, (r -> 0 ->> 'diamonds')::bigint as diamonds
  from (select public.admin_reset_diamonds('2026-09', 'gift', '2026-09') as r) q;

\i supabase/rollbacks/20261026120000_down.sql

select '2 every diamond-reset object is gone (expect 0, 0)' as check,
       (select count(*) from pg_proc where proname in ('admin_reset_diamonds', 'admin_undo_diamond_reset', 'admin_diamond_reset_preview', '_diamond_reset_plan', '_diamond_reset_actor_ok')) as fns,
       (select count(*) from information_schema.tables where table_schema = 'public' and table_name = 'diamond_reset_runs') as tbls;
select '3 the ledger rows stay and the wallet stays reset (expect -1000, 0)' as check,
       (select amount from public.wallet_ledger where kind = 'grant_reversal' and reference_table = 'diamond_reset_runs') as ledger,
       (select diamonds from public.wallets where profile_id = 'b1000000-0000-0000-0000-0000000000b1') as wallet;

\i supabase/rollbacks/20261026120000_down.sql
select '4 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'admin_reset_diamonds';

\i supabase/migrations/20261026120000_diamond_reset.sql
select '5 re-applied: the preview works again (expect 0 diamonds: the wallet is already empty)' as check, (public.admin_diamond_reset_preview('2026-09') -> 'gift' ->> 'diamonds')::bigint as gift;
