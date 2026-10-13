-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/tulasi_game_curation_test.sql
-- Proves (20261013140000): a game pushed without `status` is not switched off (new = on, existing keeps its value), expirationDate is read as
-- Beijing time, only https picture links are stored, the platform's push never changes `hidden`, only an admin can hide / show games (many at
-- once), and a hidden or switched-off game gets no launch token.
insert into auth.users (id, email) values
  ('a9400000-0000-0000-0000-000000000001', 'player94@x'),
  ('b9400000-0000-0000-0000-000000000002', 'xadmin94@x');
update public.profiles set date_of_birth = '1990-05-05' where id = 'a9400000-0000-0000-0000-000000000001';
insert into public.staff_roles (user_id, role) values ('b9400000-0000-0000-0000-000000000002', 'admin');
select set_config('request.jwt.claim.sub', '', false);
update public.app_config set feature_flags = feature_flags || '{"games_enabled": true}'::jsonb;

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

-- 1. what the Request Tester sends: no status, a relative picture path
select public.game_sync_list('[
  {"id": 2883, "merchantId": 1503251, "name": "Teen Patti Gold", "image": "/upload/2025/03/26/png/a.png", "gameIdentification": "kingdoms"},
  {"id": 2882, "merchantId": 1503251, "name": "Teen Patti", "image": "https://cos.example/b.png", "gameIdentification": "kingdoms2", "status": 0}
]'::jsonb);
select '1 a new game with no status starts enabled; one sent as 0 stays 0 (expect 1, 0)' as check,
       (select status from public.merchant_games where id = 2883) as no_status, (select status from public.merchant_games where id = 2882) as zero;
select '1b a relative picture path is not stored; an https link is (expect null, https://cos.example/b.png)' as check,
       (select image_url from public.merchant_games where id = 2883) as relative, (select image_url from public.merchant_games where id = 2882) as https;

-- 2. a later push without status keeps what is there
select public.game_sync_list('[{"id": 2883, "name": "Teen Patti Gold"}, {"id": 2882, "name": "Teen Patti"}]'::jsonb);
select '2 no status on an existing game keeps its status (expect 1, 0)' as check,
       (select status from public.merchant_games where id = 2883) as kept_on, (select status from public.merchant_games where id = 2882) as kept_off;

-- 3. the time zone and the scheme
select public.game_sync_list('[{"id": 2883, "name": "Teen Patti Gold", "status": 1, "expirationDate": "2026-12-31 23:59:59", "image": "http://insecure.example/a.png", "banner": "javascript:alert(1)"}]'::jsonb);
select '3 expirationDate is Beijing time (expect 2026-12-31 15:59:59 in UTC)' as check, (select expiration_date at time zone 'UTC' from public.merchant_games where id = 2883) as expires_utc;
select '3b http and other schemes are dropped (expect null, null)' as check, (select image_url from public.merchant_games where id = 2883) as img, (select banner_url from public.merchant_games where id = 2883) as banner;

-- 4. hide / show: admins only, many at once
select public.game_sync_list('[{"id": 2883, "name": "Teen Patti Gold", "status": 1}, {"id": 2882, "name": "Teen Patti", "status": 1}, {"id": 2881, "name": "Lucky77", "status": 1}]'::jsonb);
select set_config('request.jwt.claim.sub', 'a9400000-0000-0000-0000-000000000001', false);
select '4 a player cannot hide games (expect t)' as check, pg_temp.refused('select public.admin_set_games_hidden(array[2883]::bigint[], true)', 'Not allowed%') as ok;
select set_config('request.jwt.claim.sub', 'b9400000-0000-0000-0000-000000000002', false);
select '4b an admin hides two games at once; hiding them again changes nothing (expect 2, 0)' as check,
       public.admin_set_games_hidden(array[2883, 2882]::bigint[], true) as first, public.admin_set_games_hidden(array[2883, 2882]::bigint[], true) as again;
select set_config('request.jwt.claim.sub', '', false);
select public.game_sync_list('[{"id": 2883, "name": "Teen Patti Gold renamed", "status": 1}, {"id": 2882, "name": "Teen Patti", "status": 1}, {"id": 2881, "name": "Lucky77", "status": 1}]'::jsonb);
select '4c the platform''s push does not unhide them (expect 2 hidden, and the rename went through)' as check,
       (select count(*) from public.merchant_games where hidden) as hidden, (select name from public.merchant_games where id = 2883) as name;

-- 5. a launch of a hidden / switched-off game is refused, a shown one works
select set_config('request.jwt.claim.sub', 'a9400000-0000-0000-0000-000000000001', false);
select '5 a hidden game gets no token (expect t)' as check, pg_temp.refused('select public.start_game_session(''2883'')', 'This game is not available%') as ok;
select set_config('request.jwt.claim.sub', 'b9400000-0000-0000-0000-000000000002', false);
select public.admin_set_games_hidden(array[2883]::bigint[], false);
select set_config('request.jwt.claim.sub', 'a9400000-0000-0000-0000-000000000001', false);
select '5b once shown it launches (expect 32-character token)' as check, length(public.start_game_session('2883') ->> 'token') as token_length;
select set_config('request.jwt.claim.sub', '', false);
select public.game_sync_list('[{"id": 2881, "name": "Lucky77", "status": 0}, {"id": 2883, "name": "Teen Patti Gold", "status": 1}]'::jsonb);
select set_config('request.jwt.claim.sub', 'a9400000-0000-0000-0000-000000000001', false);
select '5c a game the platform switched off gets no token (expect t)' as check, pg_temp.refused('select public.start_game_session(''2881'')', 'This game is not available%') as ok;
select '5d the old call without a game still works (expect 32)' as check, length(public.start_game_session() ->> 'token') as token_length;

-- 6. permissions
select '6 anon cannot hide games; signed-in can call it (the function itself checks the role) (expect f, t)' as check,
       has_function_privilege('anon', 'public.admin_set_games_hidden(bigint[], boolean)', 'execute') as anon,
       has_function_privilege('authenticated', 'public.admin_set_games_hidden(bigint[], boolean)', 'execute') as authed;
