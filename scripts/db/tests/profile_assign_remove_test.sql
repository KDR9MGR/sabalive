-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/profile_assign_remove_test.sql
-- Proves (20261012100000): a Master can assign Bag items and take them back, take a badge / frame off a user, and
-- delete a host assignment; the gate is the "View user profile" switch (not "Manage users"); a non-staff account is
-- refused everywhere; the new functions are not callable by anon.
insert into auth.users (id, email) values
  ('a8000000-0000-0000-0000-000000000001', 'master8@x'),
  ('b8000000-0000-0000-0000-000000000002', 'target8@x'),
  ('c8000000-0000-0000-0000-000000000003', 'nobody8@x'),
  ('d8000000-0000-0000-0000-000000000004', 'host8@x');
insert into public.staff_roles (user_id, role) values ('a8000000-0000-0000-0000-000000000001', 'admin');
insert into public.store_items (id, category, name, emoji, price_coins, duration_days) values
  ('11111111-8888-0000-0000-000000000001', 'frame', 'T frame', 'F', 10, 7),
  ('11111111-8888-0000-0000-000000000002', 'vip', 'T lucky', 'L', 10, 7);
insert into public.badges (id, name, emoji) values ('22222222-8888-0000-0000-000000000001', 'T badge', 'B');
insert into public.frames (id, name, emoji) values ('33333333-8888-0000-0000-000000000001', 'T pframe', 'P');
insert into public.user_badges (profile_id, badge_id) values ('b8000000-0000-0000-0000-000000000002', '22222222-8888-0000-0000-000000000001');
insert into public.user_frames (profile_id, frame_id) values ('b8000000-0000-0000-0000-000000000002', '33333333-8888-0000-0000-000000000001');

-- 1. a non-staff account is refused on every function
select set_config('request.jwt.claim.sub', 'c8000000-0000-0000-0000-000000000003', false);
do $$ begin
  begin perform public.admin_assign_store_item('b8000000-0000-0000-0000-000000000002', '11111111-8888-0000-0000-000000000001', 3, false); raise exception 'no refusal';
  exception when others then if sqlerrm not like 'Only a Master%' then raise; end if; end;
  begin perform public.admin_remove_user_badge('b8000000-0000-0000-0000-000000000002', '22222222-8888-0000-0000-000000000001'); raise exception 'no refusal';
  exception when others then if sqlerrm not like 'Not allowed%' then raise; end if; end;
  begin perform public.admin_remove_user_frame('b8000000-0000-0000-0000-000000000002', '33333333-8888-0000-0000-000000000001'); raise exception 'no refusal';
  exception when others then if sqlerrm not like 'Not allowed%' then raise; end if; end;
  begin perform public.admin_assign_lucky_id(gen_random_uuid(), 'b8000000-0000-0000-0000-000000000002', 3); raise exception 'no refusal';
  exception when others then if sqlerrm not like 'Only a Master%' then raise; end if; end;
end $$;
select '1 a non-staff account is refused on all four (expect t)' as check, true as ok;

-- 2. the Master assigns an item, again (extends), and a Lucky ID item is refused
select set_config('request.jwt.claim.sub', 'a8000000-0000-0000-0000-000000000001', false);
select public.admin_assign_store_item('b8000000-0000-0000-0000-000000000002', '11111111-8888-0000-0000-000000000001', 7, false);
select '2 item assigned for about 7 days (expect t)' as check,
       expires_at between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour' as ok
  from public.user_items where profile_id = 'b8000000-0000-0000-0000-000000000002';
select public.admin_assign_store_item('b8000000-0000-0000-0000-000000000002', '11111111-8888-0000-0000-000000000001', 7, false);
select '2b assigning again extends the same copy, no second row (expect 1 row, about 14 days)' as check, count(*) as n,
       bool_and(expires_at between now() + interval '13 days 23 hours' and now() + interval '14 days 1 hour') as ok
  from public.user_items where profile_id = 'b8000000-0000-0000-0000-000000000002';
do $$ begin
  perform public.admin_assign_store_item('b8000000-0000-0000-0000-000000000002', '11111111-8888-0000-0000-000000000002', 3, false);
  raise exception 'no refusal';
exception when others then if sqlerrm not like 'Lucky IDs are assigned%' then raise; end if; end $$;
select '2c a Lucky ID item is refused (expect t)' as check, true as ok;

-- 3. the gate is "View user profile": "Manage users" off does not stop a Master, "View user profile" off does
update public.staff_roles set permissions = '{"manage_users": false}' where user_id = 'a8000000-0000-0000-0000-000000000001';
select public.admin_assign_store_item('b8000000-0000-0000-0000-000000000002', '11111111-8888-0000-0000-000000000001', 1, false);
select '3 Manage users switched off: still allowed (expect t)' as check, true as ok;
update public.staff_roles set permissions = '{"view_user_profile": false}' where user_id = 'a8000000-0000-0000-0000-000000000001';
do $$ begin
  perform public.admin_assign_store_item('b8000000-0000-0000-0000-000000000002', '11111111-8888-0000-0000-000000000001', 1, false);
  raise exception 'no refusal';
exception when others then if sqlerrm not like 'Only a Master%' then raise; end if; end $$;
select '3b View user profile switched off: refused (expect t)' as check, true as ok;
update public.staff_roles set permissions = '{}' where user_id = 'a8000000-0000-0000-0000-000000000001';

-- 4. remove the item, a badge and a frame; the second try says so
select public.admin_remove_user_item(id) from public.user_items where profile_id = 'b8000000-0000-0000-0000-000000000002';
select '4 item removed (expect 0)' as check, count(*) as n from public.user_items where profile_id = 'b8000000-0000-0000-0000-000000000002';
select public.admin_remove_user_badge('b8000000-0000-0000-0000-000000000002', '22222222-8888-0000-0000-000000000001');
select '4b badge removed (expect 0)' as check, count(*) as n from public.user_badges where profile_id = 'b8000000-0000-0000-0000-000000000002';
select public.admin_remove_user_frame('b8000000-0000-0000-0000-000000000002', '33333333-8888-0000-0000-000000000001');
select '4c frame removed (expect 0)' as check, count(*) as n from public.user_frames where profile_id = 'b8000000-0000-0000-0000-000000000002';
do $$ begin
  perform public.admin_remove_user_badge('b8000000-0000-0000-0000-000000000002', '22222222-8888-0000-0000-000000000001');
  raise exception 'no refusal';
exception when others then if sqlerrm not like 'That user does not have that badge' then raise; end if; end $$;
do $$ begin
  perform public.admin_remove_user_frame('b8000000-0000-0000-0000-000000000002', '33333333-8888-0000-0000-000000000001');
  raise exception 'no refusal';
exception when others then if sqlerrm not like 'That user does not have that frame' then raise; end if; end $$;
select '4d removing what is not there says so (expect t)' as check, true as ok;
select '4e everything was audited (expect 4+: assigned x3, removed item/badge/frame)' as check, count(*) as n
  from public.audit_logs where action in ('user.item_assigned', 'user.item_removed', 'user.badge_removed', 'user.frame_removed');

-- 5. the permissions: anon cannot run the new functions, signed-in users can reach them (the function itself then decides)
select '5 anon cannot execute admin_remove_user_badge (expect f)' as check, has_function_privilege('anon', 'public.admin_remove_user_badge(uuid,uuid)', 'execute') as ok;
select '5b authenticated can (expect t)' as check, has_function_privilege('authenticated', 'public.admin_remove_user_frame(uuid,uuid)', 'execute') as ok;

-- 6. row policies, as a signed-in user (not the superuser): a Master may delete a host assignment, a stranger may not
insert into public.assignments (id, host_id, sub_admin_id) values ('44444444-8888-0000-0000-000000000001', 'd8000000-0000-0000-0000-000000000004', 'a8000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub', 'c8000000-0000-0000-0000-000000000003', false);
set role authenticated;
with d as (delete from public.assignments where id = '44444444-8888-0000-0000-000000000001' returning 1) select '6 a stranger deletes nothing (expect 0)' as check, count(*) as n from d;
reset role;
select set_config('request.jwt.claim.sub', 'a8000000-0000-0000-0000-000000000001', false);
set role authenticated;
with d as (delete from public.assignments where id = '44444444-8888-0000-0000-000000000001' returning 1) select '6b the Master deletes it (expect 1)' as check, count(*) as n from d;
reset role;
