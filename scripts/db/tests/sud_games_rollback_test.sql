-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/sud_games_rollback_test.sql
-- Proves supabase/rollbacks/20261026110000_down.sql: every SUD object is gone, coins a SUD coin game already moved stay in the ledger, Tulasi's games still work,
-- a second run is harmless, and the migration applies again.
insert into auth.users (id, email) values ('b1000000-0000-0000-0000-0000000000b2', 'p1@x'), ('e1000000-0000-0000-0000-0000000000e6', 'super@x'), ('a1000000-0000-0000-0000-0000000000a1', 'admin@x');
insert into public.staff_roles (user_id, role) values ('a1000000-0000-0000-0000-0000000000a1', 'admin'), ('e1000000-0000-0000-0000-0000000000e6', 'super_admin');
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values ('b1000000-0000-0000-0000-0000000000b2', 'purchase', 'coins', 1000, 'coin_purchases', 'funds');
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-0000000000e6', false);
update public.app_config set feature_flags = coalesce(feature_flags, '{}'::jsonb) || '{"games_enabled": true, "sud_games_enabled": true, "sud_coin_games_enabled": true}'::jsonb where id;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-0000000000a1', false);
select public.admin_save_sud_game('1557194487352053761', 'TeenPatti', 1.0, true);
select '1 before: a bet works (expect 0)' as check, (public.sud_apply_score('b1000000-0000-0000-0000-0000000000b2', 'o1', '1557194487352053761', 'r1', 100, 1) ->> 'code')::int as code;

\i supabase/rollbacks/20261026110000_down.sql

select '2 every SUD object is gone (expect 0, 0, 0)' as check,
       (select count(*) from pg_proc where proname like 'sud\_%' or proname like '\_sud\_%' or proname like 'admin\_%sud\_%') as fns,
       (select count(*) from information_schema.tables where table_schema = 'public' and table_name in ('sud_games', 'sud_events')) as tbls,
       (select count(*) from pg_class where relname = 'sud_game_id_seq') as seq;
select '3 the coins that were moved stay in the ledger (expect -100)' as check, amount from public.wallet_ledger where kind = 'game_bet' and note = 'sud:1557194487352053761';
select '4 Tulasi is untouched: its sync function still exists (expect 1)' as check, count(*) as n from pg_proc where proname = 'game_sync_list';

\i supabase/rollbacks/20261026110000_down.sql
select '5 a second rollback is harmless (expect 0)' as check, count(*) as n from pg_proc where proname = 'sud_apply_score';

\i supabase/migrations/20261026110000_sud_games.sql
select public.admin_save_sud_game('1468180338417074177', 'Ludo');
select '6 re-applied: the list works again (expect 1)' as check, count(*) as n from public.sud_games;
