-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/panel_batch_20261031_rollback_test.sql
-- Proves supabase/rollbacks/20261031100000_down.sql runs on a database that has the migration, and that the old behaviour is back afterwards.
create function pg_temp.expect(label text, ok boolean) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.fails(stmt text) returns boolean language plpgsql as $$
begin execute stmt; return false; exception when others then return true; end $$;

insert into public.store_items (id, category, name, emoji, price_coins, duration_days) values
  ('f2000001-0000-0000-0000-000000000001', 'entry_effect', 'Free entry', 'F', 0, 30);
\i supabase/rollbacks/20261031100000_down.sql
select pg_temp.expect('the lock and Host tag columns are gone',
  not exists (select 1 from information_schema.columns where table_schema = 'public' and column_name in ('locked', 'auto_for_hosts') and table_name in ('frames', 'store_items', 'profile_tags')));
select pg_temp.expect('the new functions and triggers are gone',
  not exists (select 1 from pg_proc where proname in ('admin_set_host_auto_tag', 'admin_give_host_tag_to_current_hosts', 'frame_is_locked', 'guard_locked_flag', 'host_accepted_gets_tag', '_give_host_tag'))
  and not exists (select 1 from pg_trigger where tgname in ('host_profiles_give_tag_insert', 'host_profiles_give_tag_update', 'host_applications_give_tag', 'frames_guard_locked', 'store_items_guard_locked')));
select pg_temp.expect('a NEW item with price 0 is refused again', pg_temp.fails($$insert into public.store_items (category, name, emoji, price_coins, duration_days) values ('entry_effect', 'Free2', 'x', 0, 30)$$));
select pg_temp.expect('the free item that already existed is still readable', (select count(*) from public.store_items where id = 'f2000001-0000-0000-0000-000000000001') = 1);
select pg_temp.expect('the other functions the migration redefined still exist',
  (select count(*) from pg_proc where proname in ('purchase_store_item', 'admin_assign_store_item')) = 2);
\echo ROLLBACK CHECKS DONE
