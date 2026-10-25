-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/level_xp_any_value_test.sql
-- Proves (20261025140000): admin_save_track_level_v3 gives a level ANY XP with no relation to the level before or after it (below the previous, above the next,
-- equal to either) and nothing else moves; it works when the ladder already ends at 2,000,000,000 (production's Wealth, where v2's shift could not); users
-- are re-levelled to the highest level whose XP they reached; level 1 stays 0, the next new level is the highest + 1, XP stays inside the integer range;
-- only Master / Super Admin; audited; the other track and the older functions are untouched.
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-0000000000a1', 'super@x'),
  ('b1000000-0000-0000-0000-0000000000b2', 'master@x'),
  ('e1000000-0000-0000-0000-0000000000e3', 'plain@x'),
  ('f1000000-0000-0000-0000-0000000000f4', 'u1@x'),
  ('f2000000-0000-0000-0000-0000000000f5', 'u2@x');
insert into public.staff_roles (user_id, role, permissions) values
  ('a1000000-0000-0000-0000-0000000000a1', 'super_admin', '{}'),
  ('b1000000-0000-0000-0000-0000000000b2', 'admin', '{}');

create or replace function pg_temp.as_user(p_id text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_id, false); $$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
create or replace function pg_temp.xps(p_track text) returns text language sql as $$
  select string_agg(xp_required::text, ',' order by level) from public.track_levels where track = p_track and level <= 6;
$$;

-- the production Wealth shape: a ladder that ENDS at 2,000,000,000 (level 6 here), and a normal Charm ladder
delete from public.track_levels;
insert into public.track_levels (track, level, xp_required) values
  ('wealth', 1, 0), ('wealth', 2, 2000), ('wealth', 3, 4000), ('wealth', 4, 8000), ('wealth', 5, 1000000000), ('wealth', 6, 2000000000),
  ('charm', 1, 0), ('charm', 2, 500), ('charm', 3, 2000), ('charm', 4, 4500), ('charm', 5, 8000), ('charm', 6, 12500);
update public.profiles set wealth_xp = 3000, wealth_level = 2, charm_xp = 3000, charm_level = 3 where id = 'f1000000-0000-0000-0000-0000000000f4';
update public.profiles set wealth_xp = 9000, wealth_level = 4, charm_xp = 100, charm_level = 1 where id = 'f2000000-0000-0000-0000-0000000000f5';

select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e3');
select '1 a normal user is refused (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v3(''wealth'', 2, 600)', 'Only a Master%') as ok;
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');

-- 2. above the NEXT level: v1 refused it, v2 needed a shift; here nothing else moves
select public.admin_save_track_level_v3('wealth', 2, 5000);
select '2 level 2 to 5000, above level 3 (4000) and level 4 (8000 stays above): nothing else moves (expect 0,5000,4000,8000,1000000000,2000000000)' as check, pg_temp.xps('wealth') as xps;

-- 3. below the PREVIOUS level
select public.admin_save_track_level_v3('wealth', 4, 100);
select '3 level 4 to 100, below level 3 (expect 0,5000,4000,100,1000000000,2000000000)' as check, pg_temp.xps('wealth') as xps;

-- 4. equal to a neighbour
select public.admin_save_track_level_v3('wealth', 3, 5000);
select '4 level 3 equal to level 2 (expect 0,5000,5000,100,1000000000,2000000000)' as check, pg_temp.xps('wealth') as xps;

-- 5. THE REPORTED CASE: a ladder that already ends at 2,000,000,000 (v2 refused every edit that needed a shift): any edit works
select public.admin_save_track_level_v3('wealth', 2, 2147483647);
select '5 level 2 to the largest allowed number, above the 2,000,000,000 top level (expect 0,2147483647,5000,100,1000000000,2000000000)' as check, pg_temp.xps('wealth') as xps;
select public.admin_save_track_level_v3('wealth', 6, 0);
select '5b the top level can be set to 0 too (expect ...,1000000000,0)' as check, pg_temp.xps('wealth') as xps;
select public.admin_save_track_level_v3('wealth', 6, 2000000000);

-- 6. users are re-levelled: the highest level whose XP they reached
--    ladder now: L1 0, L2 2147483647, L3 5000, L4 100, L5 1000000000, L6 2000000000
select '6 u1 has 3000 XP: only levels 1 (0) and 4 (100) are reached, so level 4; u2 has 9000 XP: levels 1, 3 (5000), 4: level 4 (expect 4, 4)' as check,
       (select wealth_level from public.profiles where id = 'f1000000-0000-0000-0000-0000000000f4') as u1,
       (select wealth_level from public.profiles where id = 'f2000000-0000-0000-0000-0000000000f5') as u2;
select '6b the charm levels did not move (expect 3, 1)' as check,
       (select charm_level from public.profiles where id = 'f1000000-0000-0000-0000-0000000000f4') as u1,
       (select charm_level from public.profiles where id = 'f2000000-0000-0000-0000-0000000000f5') as u2;
select '6c the charm ladder is untouched (expect 0,500,2000,4500,8000,12500)' as check, pg_temp.xps('charm') as xps;

-- 7. the rules that are not about the neighbours
select '7 level 1 stays 0 (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v3(''wealth'', 1, 5)', 'Level 1 always needs 0 XP') as ok;
select '7b a level two past the top is not the next level (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v3(''wealth'', 8, 5)', 'The next new level is 7') as ok;
select public.admin_save_track_level_v3('wealth', 7, 3);
select '7c the next new level can be added, with any XP (expect 3)' as check, xp_required from public.track_levels where track = 'wealth' and level = 7;
select '7d a negative XP is refused (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v3(''wealth'', 3, -1)', 'XP must be 0 or more') as ok;
select '7e a number over the integer range is refused whatever the message (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v3(''wealth'', 3, 2147483648)', '%') as ok;
select '7f a wrong track is refused (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v3(''coins'', 3, 5)', 'Track must be wealth or charm') as ok;

-- 8. the picture rides along; a level saved with a new image keeps working; audit lines name the number
select public.admin_save_track_level_v3('charm', 3, 2100, 'https://example.com/lv3.png');
select '8 the image is stored (expect https://example.com/lv3.png, 2100)' as check, image_url, xp_required from public.track_levels where track = 'charm' and level = 3;
select '8b audited with the number (expect 1)' as check, count(*) as n from public.audit_logs where action = 'levels.saved' and target = 'charm level 3 = 2100 XP';

-- 9. Super Admin too; the older functions still behave as they did
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select public.admin_save_track_level_v3('charm', 2, 700);
select '9 Super Admin can use it (expect 700)' as check, xp_required from public.track_levels where track = 'charm' and level = 2;
select '9b the strict v1 still refuses an XP past the next level (expect t)' as check, pg_temp.refused('select public.admin_save_track_level(''charm'', 4, 99999)', 'Level 4 needs less than%') as ok;
select '9c v2 still refuses it without the switch (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v2(''charm'', 4, 99999)', 'Level 4 needs less than%') as ok;

select '10 anon cannot call it (expect f, t)' as check,
       has_function_privilege('anon', 'public.admin_save_track_level_v3(text,integer,integer,text)', 'execute') as anon,
       has_function_privilege('authenticated', 'public.admin_save_track_level_v3(text,integer,integer,text)', 'execute') as authed;
