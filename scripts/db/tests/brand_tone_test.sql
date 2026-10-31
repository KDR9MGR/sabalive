-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/brand_tone_test.sql    (every line must say ok)
-- Proves migration 20261031110000: the new column defaults to 'rich', accepts the three tones and nothing else, and the rollback removes it.
create function pg_temp.expect(label text, ok boolean) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', label; end if;
  raise notice 'ok  %', label;
end $$;
create function pg_temp.fails(stmt text) returns boolean language plpgsql as $$
begin execute stmt; return false; exception when others then return true; end $$;

select pg_temp.expect('the existing app_config row defaults to the Rich tone', (select brand_tone from public.app_config limit 1) = 'rich');
update public.app_config set brand_tone = 'soft';
select pg_temp.expect('Soft is accepted', (select brand_tone from public.app_config limit 1) = 'soft');
update public.app_config set brand_tone = 'deep';
select pg_temp.expect('Deep is accepted', (select brand_tone from public.app_config limit 1) = 'deep');
select pg_temp.expect('anything else is refused', pg_temp.fails($$update public.app_config set brand_tone = 'neon'$$));
select pg_temp.expect('an empty value is refused', pg_temp.fails($$update public.app_config set brand_tone = ''$$));
select pg_temp.expect('null is refused', pg_temp.fails($$update public.app_config set brand_tone = null$$));
\i supabase/rollbacks/20261031110000_down.sql
select pg_temp.expect('the rollback removes the column', not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'app_config' and column_name = 'brand_tone'));
\echo BRAND_TONE CHECKS DONE
