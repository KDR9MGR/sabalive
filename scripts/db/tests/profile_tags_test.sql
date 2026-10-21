-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/profile_tags_test.sql
-- Proves (20261021190000): Super Admin and a Master manage tags by default, a Master with an explicit false and every other staff account do not,
-- a lower role does once its permissions say manage_tags = true; tags are validated (name, colour, status, duplicates); a user's tags are set
-- exactly, at most 10, never on a ghost, an inactive tag cannot be given but can stay; deleting a tag takes it off everyone; the edits are audited;
-- signed-in users read active tags and assignments, nobody can write the tables directly; Access Control accepts the new key.
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'super@x'),
  ('b1000000-0000-0000-0000-000000000002', 'master@x'),
  ('b2000000-0000-0000-0000-000000000003', 'master2@x'),
  ('c1000000-0000-0000-0000-000000000004', 'global@x'),
  ('d1000000-0000-0000-0000-000000000005', 'country@x'),
  ('e1000000-0000-0000-0000-000000000006', 'plain@x'),
  ('f1000000-0000-0000-0000-000000000007', 'user1@x'),
  ('f2000000-0000-0000-0000-000000000008', 'user2@x'),
  ('f3000000-0000-0000-0000-000000000009', 'ghost@x');
insert into public.staff_roles (user_id, role, permissions) values
  ('a1000000-0000-0000-0000-000000000001', 'super_admin', '{}'),
  ('b1000000-0000-0000-0000-000000000002', 'admin', '{}'),
  ('b2000000-0000-0000-0000-000000000003', 'admin', '{"manage_tags": false}'),
  ('c1000000-0000-0000-0000-000000000004', 'global_admin', '{"manage_tags": true}'),
  ('d1000000-0000-0000-0000-000000000005', 'country_admin', '{}');
set session_replication_role = replica;
update public.profiles set is_ghost = true where id = 'f3000000-0000-0000-0000-000000000009';
set session_replication_role = origin;

create or replace function pg_temp.as_user(p_id text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_id, false); $$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;

-- 1. who may manage tags
select pg_temp.as_user('a1000000-0000-0000-0000-000000000001');
select '1 Super Admin (expect t)' as check, public.staff_can_manage_tags() as ok;
select pg_temp.as_user('b1000000-0000-0000-0000-000000000002');
select '1b a Master by default (expect t)' as check, public.staff_can_manage_tags() as ok;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000003');
select '1c a Master with an explicit false (expect f)' as check, public.staff_can_manage_tags() as ok;
select pg_temp.as_user('c1000000-0000-0000-0000-000000000004');
select '1d a Global Admin with manage_tags = true (expect t)' as check, public.staff_can_manage_tags() as ok;
select pg_temp.as_user('d1000000-0000-0000-0000-000000000005');
select '1e a Country Admin without it (expect f)' as check, public.staff_can_manage_tags() as ok;
select pg_temp.as_user('e1000000-0000-0000-0000-000000000006');
select '1f a normal user (expect f)' as check, public.staff_can_manage_tags() as ok;
select pg_temp.as_user('');
select '1g signed out (expect f)' as check, public.staff_can_manage_tags() as ok;

-- 2. refusals on every function
select pg_temp.as_user('e1000000-0000-0000-0000-000000000006');
select '2 a normal user cannot save (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(null, ''X'', ''#112233'', null, ''active'', 0)', 'Only a Master%') as ok;
select '2b cannot set user tags (expect t)' as check, pg_temp.refused('select public.admin_set_user_tags(''f1000000-0000-0000-0000-000000000007'', ''{}'')', 'Only a Master%') as ok;
select '2c cannot delete (expect t)' as check, pg_temp.refused('select public.admin_delete_profile_tag(gen_random_uuid())', 'Only a Master%') as ok;
select pg_temp.as_user('d1000000-0000-0000-0000-000000000005');
select '2d a Country Admin without the grant cannot save (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(null, ''X'', ''#112233'', null, ''active'', 0)', 'Only a Master%') as ok;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000003');
select '2e a Master with an explicit false cannot save (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(null, ''X'', ''#112233'', null, ''active'', 0)', 'Only a Master%') as ok;

-- 3. creating and validating tags (as the Master)
select pg_temp.as_user('b1000000-0000-0000-0000-000000000002');
create temp table t1 as select * from public.admin_save_profile_tag(null, '  Official  ', '#7C3AED', '✔️', 'active', 1);
select '3 a tag is created, trimmed, colour in lower case (expect Official, #7c3aed, ✔️, active)' as check, name, color, emoji, status from t1;
create temp table t2 as select * from public.admin_save_profile_tag(null, 'Top fan', '#ff2d55', '', 'active', 2);
select '3b a blank emoji is stored as nothing (expect t)' as check, emoji is null as ok from t2;
select '3c the same name in another case is refused (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(null, ''OFFICIAL'', ''#112233'', null, ''active'', 0)', 'There is already a tag called%') as ok;
select '3d a bad colour is refused (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(null, ''Y'', ''red'', null, ''active'', 0)', 'Pick a colour%') as ok;
select '3e a name over 24 characters is refused (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(null, repeat(''a'', 25), ''#112233'', null, ''active'', 0)', 'A tag name is 1 to 24%') as ok;
select '3f an empty name is refused (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(null, ''   '', ''#112233'', null, ''active'', 0)', 'A tag name is 1 to 24%') as ok;
select '3g a bad status is refused (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(null, ''Z'', ''#112233'', null, ''gone'', 0)', 'Status must be%') as ok;
create temp table t3 as select * from public.admin_save_profile_tag((select id from t2), 'Top fan!', '#00ff88', null, 'active', 5);
select '3h editing keeps the id and changes the rest (expect t, Top fan!, #00ff88, 5)' as check, t3.id = t2.id as same_id, t3.name, t3.color, t3.sort_order from t3, t2;
select '3i editing a tag that is gone is refused (expect t)' as check, pg_temp.refused('select public.admin_save_profile_tag(gen_random_uuid(), ''Q'', ''#112233'', null, ''active'', 0)', 'That tag no longer exists%') as ok;
select '3j create + edit are audited (expect 2 create, 1 update)' as check,
       (select count(*) from public.audit_logs where action = 'profile_tag.create') as created,
       (select count(*) from public.audit_logs where action = 'profile_tag.update') as updated;

-- 3b. the three looks: pill (colour), picture (banner image with the name inside), plate (background image, the app writes the name)
select '3k a picture look without a picture is refused (expect t)' as check,
       pg_temp.refused('select public.admin_save_profile_tag(null, ''Viscount'', ''#112233'', null, ''active'', 0, ''picture'', null, null)', 'Upload a picture%') as ok;
select '3l a picture from outside this project''s storage is refused (expect t)' as check,
       pg_temp.refused('select public.admin_save_profile_tag(null, ''Viscount'', ''#112233'', null, ''active'', 0, ''picture'', ''https://evil.example.com/x.png'', null)', 'The picture must be a file uploaded%') as ok;
select '3m a look that is none of the three is refused (expect t)' as check,
       pg_temp.refused('select public.admin_save_profile_tag(null, ''Viscount'', ''#112233'', null, ''active'', 0, ''banner'', null, null)', 'The look must be%') as ok;
select '3n a bad text colour is refused (expect t)' as check,
       pg_temp.refused('select public.admin_save_profile_tag(null, ''Viscount'', ''#112233'', null, ''active'', 0, ''plate'', ''https://abc123.supabase.co/storage/v1/object/public/gift-assets/tags/a.png'', ''white'')', 'The text colour must%') as ok;
create temp table t4 as select * from public.admin_save_profile_tag(null, 'Viscount', '#112233', null, 'active', 9, 'picture', 'https://abc123.supabase.co/storage/v1/object/public/gift-assets/tags/viscount.png', null);
select '3o a picture tag is saved with its picture (expect picture, the url, null)' as check, look, image_url, text_color from t4;
create temp table t5 as select * from public.admin_save_profile_tag(null, 'Sahi BDM', '#118833', null, 'active', 10, 'plate', 'https://abc123.supabase.co/storage/v1/object/public/gift-assets/tags/green.webp', '#FFFFFF');
select '3p a plate tag keeps its text colour, lower-cased (expect plate, #ffffff)' as check, look, text_color from t5;
create temp table t6 as select * from public.admin_save_profile_tag((select id from t4), 'Viscount', '#112233', null, 'active', 9, 'pill', 'https://abc123.supabase.co/storage/v1/object/public/gift-assets/tags/viscount.png', null);
select '3q switching back to a pill drops the picture (expect pill, null)' as check, look, image_url from t6;
select '3r the table itself refuses a picture look with no picture (expect t)' as check,
       pg_temp.refused('insert into public.profile_tags (name, look) values (''Direct'', ''picture'')', '%profile_tags_picture_needs_image%') as ok;
select public.admin_delete_profile_tag((select id from t4));
select public.admin_delete_profile_tag((select id from t5));

-- 4. setting a user's tags
select '4 two tags on user 1 (expect 2)' as check, public.admin_set_user_tags('f1000000-0000-0000-0000-000000000007', array[(select id from t1), (select id from t2)]) as n;
select '4b both are stored with who gave them (expect 2, t)' as check, count(*) as n, bool_and(assigned_by = 'b1000000-0000-0000-0000-000000000002') as by_master
  from public.profile_tag_assignments where profile_id = 'f1000000-0000-0000-0000-000000000007';
select '4c a list with a repeat counts once (expect 1)' as check, public.admin_set_user_tags('f2000000-0000-0000-0000-000000000008', array[(select id from t1), (select id from t1)]) as n;
select '4d the same list again returns 2' as check, public.admin_set_user_tags('f1000000-0000-0000-0000-000000000007', array[(select id from t1), (select id from t2)]) as n;
select '4d2 ...and is not audited again (expect 2: user 1 and user 2 above)' as check, count(*) as audits from public.audit_logs where action = 'profile_tag.set_user';
select '4e dropping one returns 1' as check, public.admin_set_user_tags('f1000000-0000-0000-0000-000000000007', array[(select id from t1)]) as n;
select '4e2 ...Official stays, Top fan! is gone (expect 1, 0)' as check,
       (select count(*) from public.profile_tag_assignments where profile_id = 'f1000000-0000-0000-0000-000000000007' and tag_id = (select id from t1)) as official,
       (select count(*) from public.profile_tag_assignments where profile_id = 'f1000000-0000-0000-0000-000000000007' and tag_id = (select id from t2)) as top_fan;
select '4f an empty list clears the user and returns 0' as check, public.admin_set_user_tags('f2000000-0000-0000-0000-000000000008', '{}') as n;
select '4f2 ...nothing is left on user 2 (expect 0)' as check, count(*) as left_over from public.profile_tag_assignments where profile_id = 'f2000000-0000-0000-0000-000000000008';
select '4g a ghost cannot be tagged (expect t)' as check, pg_temp.refused('select public.admin_set_user_tags(''f3000000-0000-0000-0000-000000000009'', array[''' || (select id from t1) || '''::uuid])', 'Ghost accounts cannot be tagged%') as ok;
select '4h an unknown user is refused (expect t)' as check, pg_temp.refused('select public.admin_set_user_tags(gen_random_uuid(), ''{}'')', 'That user does not exist%') as ok;
select '4i an unknown tag is refused (expect t)' as check, pg_temp.refused('select public.admin_set_user_tags(''f1000000-0000-0000-0000-000000000007'', array[gen_random_uuid()])', 'One of the tags no longer exists%') as ok;

-- 5. inactive tags
select public.admin_save_profile_tag((select id from t2), 'Top fan!', '#00ff88', null, 'inactive', 5);
select '5 an inactive tag cannot be given to someone who does not have it (expect t)' as check,
       pg_temp.refused('select public.admin_set_user_tags(''f2000000-0000-0000-0000-000000000008'', array[''' || (select id from t2) || '''::uuid])', 'An inactive tag cannot be given%') as ok;
select public.admin_save_profile_tag((select id from t2), 'Top fan!', '#00ff88', null, 'active', 5);
select public.admin_set_user_tags('f1000000-0000-0000-0000-000000000007', array[(select id from t1), (select id from t2)]);
select public.admin_save_profile_tag((select id from t2), 'Top fan!', '#00ff88', null, 'inactive', 5);
select '5b ...but it can stay on someone who already has it (expect 2)' as check,
       public.admin_set_user_tags('f1000000-0000-0000-0000-000000000007', array[(select id from t1), (select id from t2)]) as n;
select public.admin_save_profile_tag((select id from t2), 'Top fan!', '#00ff88', null, 'active', 5);

-- 6. at most 10 tags
create temp table many as
  select (public.admin_save_profile_tag(null, 'Many ' || g, '#123456', null, 'active', g)).id as id from generate_series(1, 11) g;
select '6 eleven tags on one user is refused (expect t)' as check,
       pg_temp.refused('select public.admin_set_user_tags(''f2000000-0000-0000-0000-000000000008'', (select array_agg(id) from many))', 'A user can have at most 10 tags%') as ok;
select '6b ten is fine (expect 10)' as check, public.admin_set_user_tags('f2000000-0000-0000-0000-000000000008', (select array_agg(id) from (select id from many limit 10) x)) as n;
select public.admin_set_user_tags('f2000000-0000-0000-0000-000000000008', '{}');

-- 7. reading (as an app user, through the policies)
select pg_temp.as_user('e1000000-0000-0000-0000-000000000006');
set role authenticated;
select '7 a normal user reads the active tags, ten of them from "Many" plus Official and Top fan! (expect 13)' as check, count(*) as n from public.profile_tags;
select '7b ...and what user 1 has (expect 2)' as check, count(*) as n from public.profile_tag_assignments where profile_id = 'f1000000-0000-0000-0000-000000000007';
reset role;
select pg_temp.as_user('b1000000-0000-0000-0000-000000000002');
select public.admin_save_profile_tag((select id from t2), 'Top fan!', '#00ff88', null, 'inactive', 5);
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-000000000006', false);
set role authenticated;
select '7c an inactive tag is hidden from a normal user (expect 12)' as check, count(*) as n from public.profile_tags;
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000002', false);
select '7d ...but a tag manager still sees it (expect 13)' as check, count(*) as n from public.profile_tags;
select set_config('request.jwt.claim.sub', 'e1000000-0000-0000-0000-000000000006', false);
select '7e nobody can write the tables directly (expect t, t)' as check,
       pg_temp.refused('insert into public.profile_tags (name) values (''Sneaky'')', '%permission denied%') as insert_blocked,
       pg_temp.refused('insert into public.profile_tag_assignments (profile_id, tag_id) values (''f2000000-0000-0000-0000-000000000008'', (select id from public.profile_tags limit 1))', '%permission denied%') as assign_blocked;
reset role;
select '7f anon has no access to either table (expect f, f)' as check,
       has_table_privilege('anon', 'public.profile_tags', 'select') as tags_anon, has_table_privilege('anon', 'public.profile_tag_assignments', 'select') as assignments_anon;
select '7g anon cannot call any of the functions (expect f, f, f, f)' as check,
       has_function_privilege('anon', 'public.staff_can_manage_tags()', 'execute') as helper,
       has_function_privilege('anon', 'public.admin_save_profile_tag(uuid,text,text,text,text,integer,text,text,text)', 'execute') as save,
       has_function_privilege('anon', 'public.admin_delete_profile_tag(uuid)', 'execute') as del,
       has_function_privilege('anon', 'public.admin_set_user_tags(uuid,uuid[])', 'execute') as setter;

-- 8. deleting a tag takes it off everyone and says how many
select pg_temp.as_user('b1000000-0000-0000-0000-000000000002');
select '8 deleting Official reports its users (expect 1)' as check, public.admin_delete_profile_tag((select id from t1)) as users;
select '8b ...and it is gone from them (expect 0, 1)' as check,
       (select count(*) from public.profile_tag_assignments where tag_id = (select id from t1)) as official_left,
       (select count(*) from public.profile_tag_assignments where profile_id = 'f1000000-0000-0000-0000-000000000007') as user1_left;
select '8c deleting twice is refused (expect t)' as check, pg_temp.refused('select public.admin_delete_profile_tag(''' || (select id from t1) || '''::uuid)', 'That tag no longer exists%') as ok;
select '8d the deletes are audited as warnings (expect 3: Official and the two test tags from section 3b, warning)' as check,
       (select count(*) from public.audit_logs where action = 'profile_tag.delete') as n,
       (select min(severity) from public.audit_logs where action = 'profile_tag.delete') as severity;

-- 9. Access Control accepts the key
select pg_temp.as_user('a1000000-0000-0000-0000-000000000001');
select '9 Super Admin can switch Tags on for a Country Admin (expect t)' as check,
       (public.set_staff_permissions('d1000000-0000-0000-0000-000000000005', '{"manage_tags": true}') ->> 'manage_tags')::boolean as granted;
select pg_temp.as_user('d1000000-0000-0000-0000-000000000005');
select '9b ...and that account can then manage tags (expect t)' as check, public.staff_can_manage_tags() as ok;
select pg_temp.as_user('b1000000-0000-0000-0000-000000000002');
select '9c a Master who holds it can hand it out (expect t)' as check,
       (public.set_staff_permissions('d1000000-0000-0000-0000-000000000005', '{"manage_tags": false}') ->> 'manage_tags')::boolean = false as ok;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000003');
select '9d a Master whose own Tags switch is off cannot hand it out (expect t)' as check,
       pg_temp.refused('select public.set_staff_permissions(''d1000000-0000-0000-0000-000000000005'', ''{"manage_tags": true}'')', 'You do not have "manage_tags" yourself%') as ok;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000001');
select '9e an unknown key is still refused (expect t)' as check,
       pg_temp.refused('select public.set_staff_permissions(''d1000000-0000-0000-0000-000000000005'', ''{"manage_everything": true}'')', 'Unknown permission%') as ok;
select '9f an old key still works (expect t)' as check,
       (public.set_staff_permissions('d1000000-0000-0000-0000-000000000005', '{"view_user_profile": true}') ->> 'view_user_profile')::boolean as ok;
