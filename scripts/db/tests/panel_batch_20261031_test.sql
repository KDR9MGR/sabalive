-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/panel_batch_20261031_test.sql      (every line must say "ok"; any ERROR / FAILED line is a failure)
-- Proves migration 20261031100000: the automatic Host tag, the frame lock, free Store items, and (no database change) that a Room skin can already be assigned from the panel.
create function pg_temp.expect(label text, ok boolean) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', label; end if;
  raise notice 'ok  %', label;
end $$;
-- true when running the statement raises an error (any); runs with the CURRENT role
create function pg_temp.fails(stmt text) returns boolean language plpgsql as $$
begin execute stmt; return false; exception when others then return true; end $$;

insert into auth.users (id, email) values
  ('a1000001-0000-0000-0000-000000000001', 'super@x'),
  ('a1000002-0000-0000-0000-000000000002', 'master@x'),
  ('a1000003-0000-0000-0000-000000000003', 'framestaff@x'),
  ('a1000004-0000-0000-0000-000000000004', 'profilestaff@x'),
  ('a1000005-0000-0000-0000-000000000005', 'plain@x'),
  ('a1000006-0000-0000-0000-000000000006', 'host1@x'),
  ('a1000007-0000-0000-0000-000000000007', 'host2@x'),
  ('a1000008-0000-0000-0000-000000000008', 'host3@x'),
  ('a1000009-0000-0000-0000-000000000009', 'ghosthost@x'),
  ('a100000a-0000-0000-0000-00000000000a', 'host4@x'),
  ('a100000b-0000-0000-0000-00000000000b', 'direct@x');
update public.profiles set is_ghost = true where id = 'a1000009-0000-0000-0000-000000000009';
insert into public.staff_roles (user_id, role, permissions) values
  ('a1000001-0000-0000-0000-000000000001', 'super_admin', '{}'),
  ('a1000002-0000-0000-0000-000000000002', 'admin', '{}'),
  ('a1000003-0000-0000-0000-000000000003', 'global_admin', '{"manage_profile_frames": true}'),
  ('a1000004-0000-0000-0000-000000000004', 'global_admin', '{"view_user_profile": true}');
insert into public.agencies (id, name) values
  ('b1000001-0000-0000-0000-000000000001', 'Agency One'),
  ('b1000002-0000-0000-0000-000000000002', 'Agency Two');
insert into public.profile_tags (id, name) values
  ('c1000001-0000-0000-0000-000000000001', 'Host'),
  ('c1000002-0000-0000-0000-000000000002', 'Other');

-- =========================================================================================================== 1. automatic Host tag
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000005-0000-0000-0000-000000000005', false);
select pg_temp.fails($$select public.admin_set_host_auto_tag('c1000001-0000-0000-0000-000000000001', true)$$) as plain_refused \gset
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000002', false);
select public.admin_set_host_auto_tag('c1000002-0000-0000-0000-000000000002', true);
select public.admin_set_host_auto_tag('c1000001-0000-0000-0000-000000000001', true);
reset role;
select pg_temp.expect('an ordinary user cannot mark the host tag', :'plain_refused'::boolean);
select pg_temp.expect('marking a second tag unmarks the first (only one at a time)',
  (select array_agg(name order by name) from public.profile_tags where auto_for_hosts) = array['Host']);

-- a host application approved through an agency
insert into public.host_applications (id, applicant_id, agency_id, status) values
  ('d1000001-0000-0000-0000-000000000001', 'a1000006-0000-0000-0000-000000000006', 'b1000001-0000-0000-0000-000000000001', 'pending');
select pg_temp.expect('a pending application gives no tag',
  not exists (select 1 from public.profile_tag_assignments where profile_id = 'a1000006-0000-0000-0000-000000000006'));
update public.host_applications set status = 'approved' where id = 'd1000001-0000-0000-0000-000000000001';
select pg_temp.expect('approved application: the applicant gets the Host tag',
  exists (select 1 from public.profile_tag_assignments a join public.profile_tags t on t.id = a.tag_id where a.profile_id = 'a1000006-0000-0000-0000-000000000006' and t.name = 'Host'));
-- a direct application (no agency) is approved the same way
insert into public.host_applications (id, applicant_id, agency_id, status) values
  ('d1000002-0000-0000-0000-000000000002', 'a100000b-0000-0000-0000-00000000000b', null, 'pending');
update public.host_applications set status = 'approved' where id = 'd1000002-0000-0000-0000-000000000002';
select pg_temp.expect('a direct application (no agency) approved: the applicant gets the tag too',
  exists (select 1 from public.profile_tag_assignments where profile_id = 'a100000b-0000-0000-0000-00000000000b'));
-- a rejected application gives nothing
insert into public.host_applications (id, applicant_id, agency_id, status) values
  ('d1000003-0000-0000-0000-000000000003', 'a1000005-0000-0000-0000-000000000005', 'b1000001-0000-0000-0000-000000000001', 'pending');
update public.host_applications set status = 'rejected' where id = 'd1000003-0000-0000-0000-000000000003';
select pg_temp.expect('a rejected application gives no tag',
  not exists (select 1 from public.profile_tag_assignments where profile_id = 'a1000005-0000-0000-0000-000000000005'));

-- a host joining an agency by host code / agency approval
insert into public.host_profiles (profile_id, agency_id) values ('a1000007-0000-0000-0000-000000000007', 'b1000001-0000-0000-0000-000000000001');
select pg_temp.expect('a host row created with an agency gets the tag',
  exists (select 1 from public.profile_tag_assignments where profile_id = 'a1000007-0000-0000-0000-000000000007'));
-- an independent host (the app makes one for anyone who goes live)
insert into public.host_profiles (profile_id) values ('a1000008-0000-0000-0000-000000000008');
select pg_temp.expect('an independent host (no agency) gets no tag',
  not exists (select 1 from public.profile_tag_assignments where profile_id = 'a1000008-0000-0000-0000-000000000008'));
update public.host_profiles set agency_id = 'b1000001-0000-0000-0000-000000000001' where profile_id = 'a1000008-0000-0000-0000-000000000008';
select pg_temp.expect('...and gets it the moment an agency accepts them',
  exists (select 1 from public.profile_tag_assignments where profile_id = 'a1000008-0000-0000-0000-000000000008'));
-- a monitoring account is never tagged
insert into public.host_profiles (profile_id, agency_id) values ('a1000009-0000-0000-0000-000000000009', 'b1000001-0000-0000-0000-000000000001');
select pg_temp.expect('a monitoring (ghost) account is never tagged',
  not exists (select 1 from public.profile_tag_assignments where profile_id = 'a1000009-0000-0000-0000-000000000009'));
-- a transfer between agencies does not bring back a tag taken off by hand
delete from public.profile_tag_assignments where profile_id = 'a1000007-0000-0000-0000-000000000007';
update public.host_profiles set agency_id = 'b1000002-0000-0000-0000-000000000002' where profile_id = 'a1000007-0000-0000-0000-000000000007';
select pg_temp.expect('a transfer between agencies does not give the tag again',
  not exists (select 1 from public.profile_tag_assignments where profile_id = 'a1000007-0000-0000-0000-000000000007'));
-- an inactive tag is not given
update public.profile_tags set status = 'inactive' where id = 'c1000001-0000-0000-0000-000000000001';
insert into public.host_profiles (profile_id, agency_id) values ('a100000a-0000-0000-0000-00000000000a', 'b1000001-0000-0000-0000-000000000001');
select pg_temp.expect('an inactive tag is not given',
  not exists (select 1 from public.profile_tag_assignments where profile_id = 'a100000a-0000-0000-0000-00000000000a'));
update public.profile_tags set status = 'active' where id = 'c1000001-0000-0000-0000-000000000001';

-- the button "give it to current hosts": host2 (tag taken off) and host4 (tag was inactive) are missing it, the ghost is skipped, the others already have it
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000005-0000-0000-0000-000000000005', false);
select pg_temp.fails($$select public.admin_give_host_tag_to_current_hosts()$$) as plain_refused2 \gset
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000002', false);
select public.admin_give_host_tag_to_current_hosts() as given \gset
reset role;
select pg_temp.expect('an ordinary user cannot run it', :'plain_refused2'::boolean);
select pg_temp.expect('it adds the tag to the 2 hosts that lack it', :given = 2);
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000002', false);
select public.admin_give_host_tag_to_current_hosts() as given_again \gset
select public.admin_set_host_auto_tag('c1000001-0000-0000-0000-000000000001', false);
select pg_temp.fails($$select public.admin_give_host_tag_to_current_hosts()$$) as none_flagged \gset
reset role;
select pg_temp.expect('a second run adds nobody', :given_again = 0);
select pg_temp.expect('with no tag marked the button refuses', :'none_flagged'::boolean);
select pg_temp.expect('unmarking leaves nobody marked', not exists (select 1 from public.profile_tags where auto_for_hosts));

-- =========================================================================================================== 2. frame lock
insert into public.frames (id, name, emoji) values
  ('e1000001-0000-0000-0000-000000000001', 'Open frame', 'O'),
  ('e1000002-0000-0000-0000-000000000002', 'Reserved frame', 'R');
insert into public.store_items (id, category, name, emoji, price_coins, duration_days) values
  ('f1000001-0000-0000-0000-000000000001', 'frame', 'Store open frame', 'S', 100, 30),
  ('f1000002-0000-0000-0000-000000000002', 'frame', 'Store reserved frame', 'S', 100, 30);

set role authenticated;
-- only Super Admin / Master can lock
select set_config('request.jwt.claim.sub', 'a1000003-0000-0000-0000-000000000003', false);
select pg_temp.fails($$update public.frames set locked = true where id = 'e1000002-0000-0000-0000-000000000002'$$) as staff_lock_refused \gset
select pg_temp.fails($$insert into public.frames (name, emoji, locked) values ('Sneaky', 'x', true)$$) as staff_insert_locked_refused \gset
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000002', false);
update public.frames set locked = true where id = 'e1000002-0000-0000-0000-000000000002';
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
update public.store_items set locked = true where id = 'f1000002-0000-0000-0000-000000000002';
-- assigning a Profile Frame
select set_config('request.jwt.claim.sub', 'a1000003-0000-0000-0000-000000000003', false);
insert into public.user_frames (profile_id, frame_id) values ('a1000005-0000-0000-0000-000000000005', 'e1000001-0000-0000-0000-000000000001');
select pg_temp.fails($$insert into public.user_frames (profile_id, frame_id) values ('a1000005-0000-0000-0000-000000000005', 'e1000002-0000-0000-0000-000000000002')$$) as framestaff_locked_refused \gset
select set_config('request.jwt.claim.sub', 'a1000004-0000-0000-0000-000000000004', false);
select pg_temp.fails($$insert into public.user_frames (profile_id, frame_id) values ('a1000006-0000-0000-0000-000000000006', 'e1000002-0000-0000-0000-000000000002')$$) as profilestaff_locked_refused \gset
insert into public.user_frames (profile_id, frame_id) values ('a1000006-0000-0000-0000-000000000006', 'e1000001-0000-0000-0000-000000000001');
-- a locked Store frame through "Assign item"
select pg_temp.fails($$select public.admin_assign_store_item('a1000005-0000-0000-0000-000000000005', 'f1000002-0000-0000-0000-000000000002', 7, false)$$) as store_locked_refused \gset
select public.admin_assign_store_item('a1000005-0000-0000-0000-000000000005', 'f1000001-0000-0000-0000-000000000001', 7, false);
-- Master and Super Admin can still assign a locked one
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000002', false);
insert into public.user_frames (profile_id, frame_id) values ('a1000005-0000-0000-0000-000000000005', 'e1000002-0000-0000-0000-000000000002');
select public.admin_assign_store_item('a1000005-0000-0000-0000-000000000005', 'f1000002-0000-0000-0000-000000000002', 7, false);
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select public.admin_assign_store_item('a1000006-0000-0000-0000-000000000006', 'f1000002-0000-0000-0000-000000000002', 7, false);
-- unlocking by a Master lets the staff assign it again
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000002', false);
update public.frames set locked = false where id = 'e1000002-0000-0000-0000-000000000002';
select set_config('request.jwt.claim.sub', 'a1000003-0000-0000-0000-000000000003', false);
insert into public.user_frames (profile_id, frame_id) values ('a1000006-0000-0000-0000-000000000006', 'e1000002-0000-0000-0000-000000000002');
reset role;
select pg_temp.expect('staff cannot lock a frame', :'staff_lock_refused'::boolean);
select pg_temp.expect('staff cannot create a frame already locked', :'staff_insert_locked_refused'::boolean);
select pg_temp.expect('Master and Super Admin locked a Profile Frame and a Store frame',
  (select locked from public.frames where id = 'e1000002-0000-0000-0000-000000000002') is false  -- unlocked again at the end
  and (select locked from public.store_items where id = 'f1000002-0000-0000-0000-000000000002'));
select pg_temp.expect('an unlocked Profile Frame can be assigned by staff with the frames switch',
  exists (select 1 from public.user_frames where profile_id = 'a1000005-0000-0000-0000-000000000005' and frame_id = 'e1000001-0000-0000-0000-000000000001'));
select pg_temp.expect('a LOCKED Profile Frame is refused for staff with the frames switch', :'framestaff_locked_refused'::boolean);
select pg_temp.expect('a LOCKED Profile Frame is refused for staff with the View user profile switch', :'profilestaff_locked_refused'::boolean);
select pg_temp.expect('a locked Store frame is refused through Assign item for staff', :'store_locked_refused'::boolean);
select pg_temp.expect('an unlocked Store frame is assigned for staff',
  exists (select 1 from public.user_items where profile_id = 'a1000005-0000-0000-0000-000000000005' and item_id = 'f1000001-0000-0000-0000-000000000001'));
select pg_temp.expect('a Master can assign a locked Profile Frame and a locked Store frame',
  (select count(*) from public.user_frames where profile_id = 'a1000005-0000-0000-0000-000000000005' and frame_id = 'e1000002-0000-0000-0000-000000000002') = 1
  and exists (select 1 from public.user_items where profile_id = 'a1000005-0000-0000-0000-000000000005' and item_id = 'f1000002-0000-0000-0000-000000000002'));
select pg_temp.expect('a Super Admin can assign a locked Store frame',
  exists (select 1 from public.user_items where profile_id = 'a1000006-0000-0000-0000-000000000006' and item_id = 'f1000002-0000-0000-0000-000000000002'));
select pg_temp.expect('after unlocking, staff can assign the frame again',
  exists (select 1 from public.user_frames where profile_id = 'a1000006-0000-0000-0000-000000000006' and frame_id = 'e1000002-0000-0000-0000-000000000002'));

-- =========================================================================================================== 3. free Store items
insert into public.store_items (id, category, name, emoji, price_coins, duration_days) values
  ('f2000001-0000-0000-0000-000000000001', 'entry_effect', 'Free entry', 'F', 0, 30),
  ('f2000002-0000-0000-0000-000000000002', 'entry_effect', 'Paid entry', 'P', 150, 30);
select pg_temp.expect('a negative price is still refused',
  pg_temp.fails($$insert into public.store_items (category, name, emoji, price_coins, duration_days) values ('entry_effect', 'Bad', 'x', -1, 30)$$));
insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
values ('a1000005-0000-0000-0000-000000000005', 'purchase', 'coins', 200, 'coin_purchases', 'test funds');
select count(*) as ledger_before from public.wallet_ledger where profile_id = 'a1000005-0000-0000-0000-000000000005' \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000005-0000-0000-0000-000000000005', false);
select public.purchase_store_item('f2000001-0000-0000-0000-000000000001');
select pg_temp.fails($$select public.purchase_store_item('f2000001-0000-0000-0000-000000000001')$$) as free_twice_refused \gset
reset role;
select pg_temp.expect('a free item is added to the Bag', exists (select 1 from public.user_items where profile_id = 'a1000005-0000-0000-0000-000000000005' and item_id = 'f2000001-0000-0000-0000-000000000001'));
select pg_temp.expect('a free item costs nothing and writes no ledger row',
  (select coins from public.wallets where profile_id = 'a1000005-0000-0000-0000-000000000005') = 200
  and (select count(*) from public.wallet_ledger where profile_id = 'a1000005-0000-0000-0000-000000000005') = :ledger_before);
select pg_temp.expect('a free item already owned is refused, not extended', :'free_twice_refused'::boolean
  and (select count(*) from public.user_items where profile_id = 'a1000005-0000-0000-0000-000000000005' and item_id = 'f2000001-0000-0000-0000-000000000001') = 1);
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000005-0000-0000-0000-000000000005', false);
select public.purchase_store_item('f2000002-0000-0000-0000-000000000002');
select pg_temp.fails($$select public.purchase_store_item('f2000002-0000-0000-0000-000000000002')$$) as second_paid_ok_or_poor \gset
reset role;
select pg_temp.expect('a paid item still charges its price (200 - 150 = 50)', (select coins from public.wallets where profile_id = 'a1000005-0000-0000-0000-000000000005') = 50);
select pg_temp.expect('a paid item is still refused without enough coins (second buy needs 150, only 50 left)', :'second_paid_ok_or_poor'::boolean);

-- =========================================================================================================== 4. Room skin: assignable from the panel already
insert into public.store_items (id, category, name, emoji, price_coins, duration_days) values
  ('f3000001-0000-0000-0000-000000000001', 'room_skin', 'Test skin', 'K', 4000, 30);
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000002', false);
select public.admin_assign_store_item('a1000006-0000-0000-0000-000000000006', 'f3000001-0000-0000-0000-000000000001', 14, true);
reset role;
select pg_temp.expect('a Master can assign a Room skin from the panel and equip it',
  exists (select 1 from public.user_items where profile_id = 'a1000006-0000-0000-0000-000000000006' and item_id = 'f3000001-0000-0000-0000-000000000001' and equipped and expires_at > now() + interval '13 days'));
select pg_temp.expect('the room of that host uses that skin', public.equipped_room_skin('a1000006-0000-0000-0000-000000000006') = 'f3000001-0000-0000-0000-000000000001');
\echo ALL PANEL_BATCH_20261031 CHECKS DONE (every line above must say ok)
