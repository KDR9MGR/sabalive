-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/level_xp_free_edit_test.sql
-- Proves (20261025110000): admin_save_track_level_v2 edits any level; an XP that reaches the next level is refused unless p_shift, and with p_shift every
-- later level moves up by the same amount (gaps kept); lowering never shifts; a level can't be at or below the one before it; level 1 stays 0;
-- users are re-levelled; only Master / Super Admin; one audit line; the old function keeps its strict rule; the other track is untouched.
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

-- a clean, easy-to-read ladder for both tracks: 0, 500, 2000, 4500, 8000, 12500 ... (the first six levels are what the test reads)
delete from public.track_levels;
insert into public.track_levels (track, level, xp_required)
select t.track, l.level, v.xp
  from (values ('wealth'), ('charm')) as t(track)
 cross join (values (1, 0), (2, 500), (3, 2000), (4, 4500), (5, 8000), (6, 12500)) as v(level, xp)
 cross join lateral (select v.level as level) as l;
update public.profiles set wealth_xp = 3000, wealth_level = 3, charm_xp = 3000, charm_level = 3
 where id in ('f1000000-0000-0000-0000-0000000000f4');
update public.profiles set wealth_xp = 9000, wealth_level = 5, charm_xp = 100, charm_level = 1
 where id in ('f2000000-0000-0000-0000-0000000000f5');

-- 1. who may use it
select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e3');
select '1 a normal user is refused (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v2(''wealth'', 2, 600)', 'Only a Master%') as ok;
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');

-- 2. a plain edit between the neighbours works, shifts nothing
select '2 level 2 to 700 shifts nothing (expect 0)' as check, public.admin_save_track_level_v2('wealth', 2, 700) as shifted;
select '2b the ladder (expect 0,700,2000,4500,8000,12500)' as check, pg_temp.xps('wealth') as xps;

-- 3. reaching the next level is refused without p_shift
select '3 level 2 to 2500 without the switch is refused (expect t)' as check,
       pg_temp.refused('select public.admin_save_track_level_v2(''wealth'', 2, 2500)', 'Level 2 needs less than the 2000 XP of level 3%') as ok;
select '3b nothing changed (expect 0,700,2000,4500,8000,12500)' as check, pg_temp.xps('wealth') as xps;

-- 4. with p_shift every later level moves up by the same amount (2500 - 700 = 1800)
select '4 level 2 to 2500 with the switch moves 4 later levels (expect 4)' as check, public.admin_save_track_level_v2('wealth', 2, 2500, null, true) as shifted;
select '4b the ladder (expect 0,2500,3800,6300,9800,14300)' as check, pg_temp.xps('wealth') as xps;
select '4c the gaps are kept (expect 1300,2500,3500,4500)' as check,
       (select string_agg((b.xp_required - a.xp_required)::text, ',' order by a.level)
          from public.track_levels a join public.track_levels b on b.track = a.track and b.level = a.level + 1
         where a.track = 'wealth' and a.level between 2 and 5) as gaps;
select '4d the charm track is untouched (expect 0,500,2000,4500,8000,12500)' as check, pg_temp.xps('charm') as xps;

-- 5. everyone is re-levelled: u1 had 3000 XP (level 3 before: 2000); now level 2 (2500) and level 3 needs 3800
select '5 u1 (3000 XP) is level 2 now, u2 (9000 XP) is level 4 now (expect 2, 4)' as check,
       (select wealth_level from public.profiles where id = 'f1000000-0000-0000-0000-0000000000f4') as u1,
       (select wealth_level from public.profiles where id = 'f2000000-0000-0000-0000-0000000000f5') as u2;
select '5b the charm levels did not move (expect 3, 1)' as check,
       (select charm_level from public.profiles where id = 'f1000000-0000-0000-0000-0000000000f4') as u1,
       (select charm_level from public.profiles where id = 'f2000000-0000-0000-0000-0000000000f5') as u2;

-- 6. lowering needs no shift and is allowed with the switch too (nothing moves)
select '6 level 4 down to 4000 (expect 0)' as check, public.admin_save_track_level_v2('wealth', 4, 4000, null, true) as shifted;
select '6b ladder (expect 0,2500,3800,4000,9800,14300)' as check, pg_temp.xps('wealth') as xps;

-- 7. a level can't be at or below the one before it, even with the switch
select '7 level 4 to 3800 is refused (expect t)' as check,
       pg_temp.refused('select public.admin_save_track_level_v2(''wealth'', 4, 3800, null, true)', 'Level 4 needs more than the 3800 XP of level 3%') as ok;
select '7b level 1 stays at 0 (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v2(''wealth'', 1, 5)', 'Level 1 always needs 0 XP') as ok;
select '7c level 9 is not the next level (expect t)' as check, pg_temp.refused('select public.admin_save_track_level_v2(''wealth'', 99, 5000000)', 'The next new level is%') as ok;

-- 8. the top level can be raised freely (nothing above it) and a new level can be added
create temp table top as select max(level) as n from public.track_levels where track = 'wealth';
select '8 the top level to a huge value moves nothing (expect 0)' as check,
       public.admin_save_track_level_v2('wealth', (select n from top), (select xp_required from public.track_levels where track = 'wealth' and level = (select n from top)) + 5000, null, true) as shifted;
select '8b add the next level (expect 0)' as check, public.admin_save_track_level_v2('wealth', (select n + 1 from top), 99999999) as shifted;

-- 9. the 2,000,000,000 ceiling
select '9 a shift past the ceiling is refused (expect t)' as check,
       pg_temp.refused('select public.admin_save_track_level_v2(''charm'', 2, 1999999999, null, true)', 'The later levels would go past%') as ok;

-- 10. the picture rides along, the image is kept when saving the XP only with the same url
select '10 an image is saved, nothing shifts (expect 0)' as check, public.admin_save_track_level_v2('charm', 3, 2100, 'https://example.com/lv3.png') as shifted;
select '10b it is stored (expect https://example.com/lv3.png)' as check, image_url from public.track_levels where track = 'charm' and level = 3;

-- 11. audit lines, and the old function keeps its strict rule
select '11 audited with the number of moved levels (expect >= 1 line mentioning moved)' as check, count(*) as n
  from public.audit_logs where action = 'levels.saved' and target like 'wealth level 2 (4 later levels moved up)';
select '11b the old function still refuses an XP past the next level (expect t)' as check,
       pg_temp.refused('select public.admin_save_track_level(''charm'', 2, 5000)', 'Level 2 needs less than%') as ok;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select '11c Super Admin can use it (expect 0)' as check, public.admin_save_track_level_v2('charm', 2, 600) as shifted;
select '12 anon cannot call it (expect f, t)' as check,
       has_function_privilege('anon', 'public.admin_save_track_level_v2(text,integer,integer,text,boolean)', 'execute') as anon,
       has_function_privilege('authenticated', 'public.admin_save_track_level_v2(text,integer,integer,text,boolean)', 'execute') as authed;
