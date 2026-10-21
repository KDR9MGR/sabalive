-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/announcement_delivery_test.sql
-- Proves (20261021170000): Send now delivers to the whole audience (ghosts excluded), once, with "Title + new line + Message" as the text and a push per
-- user; an in-app-only announcement writes the notifications but sends NO push, and pushes work again right after; a big audience is delivered in
-- batches by the cron function without ever writing a user twice and ends 'sent' with the recipient count; a scheduled announcement waits for its
-- time and cancelling it makes it a draft again; only a Master with the Content switch can send, schedule or cancel; an announcement cannot be sent
-- twice; the internal functions are not callable by app users; grant_lucky_box_rewards is not either.
insert into auth.users (id, email)
select ('a' || to_hex(n) || '000000-0000-0000-0000-000000000001')::uuid, 'u' || n || '@x' from generate_series(1, 14) n;
insert into auth.users (id, email) values
  ('b1000000-0000-0000-0000-000000000001', 'master@x'),
  ('b2000000-0000-0000-0000-000000000002', 'master2@x'),
  ('c1000000-0000-0000-0000-000000000001', 'plain@x');
insert into public.staff_roles (user_id, role) values
  ('b1000000-0000-0000-0000-000000000001', 'admin'),
  ('b2000000-0000-0000-0000-000000000002', 'admin');
update public.staff_roles set permissions = '{"manage_content": false}'::jsonb where user_id = 'b2000000-0000-0000-0000-000000000002';
update public.profiles set is_ghost = true where id = 'ae000000-0000-0000-0000-000000000001';                       -- one ghost: never receives it
update public.profiles set is_host = true where id in ('a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001');

-- count the push calls (the stub's net.http_post does nothing)
create table public.push_calls (id serial primary key);
create or replace function net.http_post(url text, body jsonb default null, headers jsonb default null, params jsonb default null, timeout_milliseconds int default 1000)
returns bigint language plpgsql as $$ begin insert into public.push_calls default values; return 1; end $$;

create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

create temp table t as select
  (select count(*) from public.profiles where not coalesce(is_ghost, false)) as audience_all,
  (select count(*) from public.profiles where is_host and not coalesce(is_ghost, false)) as audience_hosts;

insert into public.announcements (id, title, body, audience, channel, status) values
  ('d1000000-0000-0000-0000-000000000001', 'Hello', 'World', 'all', 'push', 'draft'),
  ('d2000000-0000-0000-0000-000000000002', 'In app', 'Only the list', 'all', 'in_app', 'draft'),
  ('d3000000-0000-0000-0000-000000000003', 'Hosts', 'Hosts only', 'hosts', 'in_app', 'draft'),
  ('d4000000-0000-0000-0000-000000000004', 'Later', 'Scheduled one', 'all', 'in_app', 'draft'),
  ('d5000000-0000-0000-0000-000000000005', 'Batched', 'Many users', 'all', 'in_app', 'draft');

-- 1. who may
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000001', false);
select '1 a normal user cannot send (expect t)' as check, pg_temp.refused('select public.announcement_send_now(''d1000000-0000-0000-0000-000000000001'')', 'Only a Master%') as ok;
select set_config('request.jwt.claim.sub', 'b2000000-0000-0000-0000-000000000002', false);
select '1b a Master with the Content switch off cannot send, schedule or cancel (expect t, t, t)' as check,
       pg_temp.refused('select public.announcement_send_now(''d1000000-0000-0000-0000-000000000001'')', 'Only a Master%') as send,
       pg_temp.refused('select public.announcement_schedule(''d1000000-0000-0000-0000-000000000001'', now() + interval ''1 day'')', 'Only a Master%') as sched,
       pg_temp.refused('select public.announcement_cancel(''d1000000-0000-0000-0000-000000000001'')', 'Only a Master%') as cancel;
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', false);

-- 2. send now, with a push
create temp table sent1 as select public.announcement_send_now('d1000000-0000-0000-0000-000000000001') as j;
select '2 send now reaches the whole audience, ghosts excluded (expect t, sent, t)' as check,
       (select (j ->> 'delivered_now')::int = (select audience_all from t) from sent1) as all_delivered,
       (select status from public.announcements where id = 'd1000000-0000-0000-0000-000000000001') as status,
       (select recipients = (select audience_all from t) from public.announcements where id = 'd1000000-0000-0000-0000-000000000001') as recipients_ok;
select '2b the text is title + new line + message, kind announcement, one row per user (expect t, t)' as check,
       (select bool_and(body = E'Hello\nWorld' and kind = 'announcement') from public.notifications where announcement_id = 'd1000000-0000-0000-0000-000000000001') as text_ok,
       (select count(distinct profile_id) = (select audience_all from t) from public.notifications where announcement_id = 'd1000000-0000-0000-0000-000000000001') as one_each;
select '2c the ghost got nothing (expect 0)' as check, count(*) as n from public.notifications where profile_id = 'ae000000-0000-0000-0000-000000000001';
select '2d a push was sent for every user (expect t)' as check, (select count(*) from public.push_calls) = (select audience_all from t) as ok;
select '2e it cannot be sent twice (expect t)' as check, pg_temp.refused('select public.announcement_send_now(''d1000000-0000-0000-0000-000000000001'')', 'This announcement was already sent') as ok;
select '2f it is audit-logged (expect 1)' as check, count(*) as n from public.audit_logs where action = 'announcement.send';

-- 3. in-app only: no push, and pushes work again afterwards
create temp table before_push as select count(*) as n from public.push_calls;
select public.announcement_send_now('d2000000-0000-0000-0000-000000000002');
select '3 in-app only wrote the rows but sent NO push (expect t, t)' as check,
       (select count(*) from public.notifications where announcement_id = 'd2000000-0000-0000-0000-000000000002') = (select audience_all from t) as rows_ok,
       (select count(*) from public.push_calls) = (select n from before_push) as no_push;
insert into public.notifications (profile_id, kind, body) values ('a1000000-0000-0000-0000-000000000001', 'follow', 'x followed you');
select '3b a normal notification still pushes afterwards (expect t)' as check, (select count(*) from public.push_calls) = (select n from before_push) + 1 as ok;

-- 4. hosts only
select public.announcement_send_now('d3000000-0000-0000-0000-000000000003');
select '4 the hosts audience reaches only hosts (expect t, t)' as check,
       (select count(*) from public.notifications where announcement_id = 'd3000000-0000-0000-0000-000000000003') = (select audience_hosts from t) as count_ok,
       (select bool_and(p.is_host) from public.notifications n join public.profiles p on p.id = n.profile_id where n.announcement_id = 'd3000000-0000-0000-0000-000000000003') as only_hosts;

-- 5. scheduling
select '5 a past time is refused (expect t)' as check, pg_temp.refused('select public.announcement_schedule(''d4000000-0000-0000-0000-000000000004'', now() - interval ''1 hour'')', 'Pick a time in the future') as ok;
select public.announcement_schedule('d4000000-0000-0000-0000-000000000004', now() + interval '1 hour');
select public.process_announcements();
select '5b a scheduled announcement waits for its time: nothing delivered yet (expect scheduled, 0)' as check,
       (select status from public.announcements where id = 'd4000000-0000-0000-0000-000000000004') as status,
       (select count(*) from public.notifications where announcement_id = 'd4000000-0000-0000-0000-000000000004') as n;
select public.announcement_cancel('d4000000-0000-0000-0000-000000000004');
select '5c cancelling makes it a draft again (expect draft, null)' as check,
       (select status from public.announcements where id = 'd4000000-0000-0000-0000-000000000004') as status,
       (select send_at from public.announcements where id = 'd4000000-0000-0000-0000-000000000004') as send_at;
select '5d a draft cannot be cancelled (expect t)' as check, pg_temp.refused('select public.announcement_cancel(''d4000000-0000-0000-0000-000000000004'')', 'Only a scheduled announcement can be cancelled') as ok;
select public.announcement_schedule('d4000000-0000-0000-0000-000000000004', now() + interval '1 hour');
update public.announcements set send_at = now() - interval '1 minute' where id = 'd4000000-0000-0000-0000-000000000004';   -- the time arrives
select public.process_announcements();
select '5e when the time arrives the cron function delivers it (expect sent, audience)' as check,
       (select status from public.announcements where id = 'd4000000-0000-0000-0000-000000000004') as status,
       (select count(*) = (select audience_all from t) from public.notifications where announcement_id = 'd4000000-0000-0000-0000-000000000004') as delivered;

-- 6. batches: 5 at a time, nobody twice, 'sending' until the last short batch
update public.announcements set status = 'scheduled' where id = 'd5000000-0000-0000-0000-000000000005';
create temp table b1 as select public.deliver_announcement('d5000000-0000-0000-0000-000000000005', 5) as n;
select '6 batch 1 delivers 5 and the announcement stays sending (expect 5, sending)' as check, (select n from b1) as n,
       (select status from public.announcements where id = 'd5000000-0000-0000-0000-000000000005') as status;
select '6b batch 2 delivers 5 more (expect 5)' as check, public.deliver_announcement('d5000000-0000-0000-0000-000000000005', 5) as n;
select public.deliver_announcement('d5000000-0000-0000-0000-000000000005', 5);   -- batch 3: 5 more, one user is left
select '6a the 16th user comes in a short batch (expect 1)' as check, public.deliver_announcement('d5000000-0000-0000-0000-000000000005', 5) as n;
select '6c after the last short batch it is sent with the recipient count and no user got it twice (expect sent, t, t)' as check,
       (select status from public.announcements where id = 'd5000000-0000-0000-0000-000000000005') as status,
       (select recipients = (select audience_all from t) from public.announcements where id = 'd5000000-0000-0000-0000-000000000005') as recipients_ok,
       (select count(*) = count(distinct profile_id) from public.notifications where announcement_id = 'd5000000-0000-0000-0000-000000000005') as no_duplicates;
select '6d another run delivers nothing (expect 0)' as check, public.deliver_announcement('d5000000-0000-0000-0000-000000000005', 5) as n;

-- 7. grants and the cron job
select '7 app users cannot call the internal functions, signed-in users can call the three RPCs, anon cannot (expect f, f, t, t, t, f)' as check,
       has_function_privilege('authenticated', 'public.deliver_announcement(uuid,integer)', 'execute') as deliver,
       has_function_privilege('authenticated', 'public.process_announcements()', 'execute') as process,
       has_function_privilege('authenticated', 'public.announcement_send_now(uuid)', 'execute') as send_now,
       has_function_privilege('authenticated', 'public.announcement_schedule(uuid,timestamptz)', 'execute') as schedule,
       has_function_privilege('authenticated', 'public.announcement_cancel(uuid)', 'execute') as cancel,
       has_function_privilege('anon', 'public.announcement_send_now(uuid)', 'execute') as anon_send;
select '7b the Lucky Box payout is no longer callable by app users (expect f, f)' as check,
       has_function_privilege('authenticated', 'public.grant_lucky_box_rewards()', 'execute') as authed,
       has_function_privilege('anon', 'public.grant_lucky_box_rewards()', 'execute') as anon;
-- (the scratch cron stand-in records no jobs; the 'process-announcements' job is checked on production after the push)
select set_config('request.jwt.claim.sub', '', false);
