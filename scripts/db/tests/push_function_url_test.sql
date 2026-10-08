-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/push_function_url_test.sql
-- Proves push_notification() posts to the configured address, and to production's only when none is set.
-- Replaces the net.http_post stub with one that records the URL it was asked to call.
create table public.zz_calls (n serial, url text);
create or replace function net.http_post(url text, body jsonb default null, headers jsonb default null,
                                         params jsonb default null, timeout_milliseconds int default 1000)
returns bigint language plpgsql as $$ begin insert into public.zz_calls (url) values (url); return 1; end $$;

insert into auth.users (id, email) values ('c3000000-0000-0000-0000-000000000001', 'push@x');
create or replace function pg_temp.fire() returns text language plpgsql as $$
begin
  insert into public.notifications (profile_id, kind, body) values ('c3000000-0000-0000-0000-000000000001', 'test', 'hi');
  return (select url from public.zz_calls order by n desc limit 1);
end $$;

select '1 no secret -> production address (behaviour unchanged)' as case, pg_temp.fire() as url;
select vault.create_secret('https://stagingref.supabase.co/', 'functions_base_url');
select '2 secret set (with trailing slash) -> staging address' as case, pg_temp.fire() as url;
update vault.secrets set secret = '   ' where name = 'functions_base_url';
select '3 blank secret -> falls back to production' as case, pg_temp.fire() as url;
