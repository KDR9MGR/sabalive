-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/country_admin_global_link_test.sql
-- Proves (20261026100000): the back-fill gives a Country Admin the Global Admin who created them (and only a Global Admin: not a Master, not someone no longer
-- staff); a Country Admin created from now on by a Global Admin is linked by the trigger and one created by a Master is not; the trigger never breaks an account
-- creation; transfer_country_admin lets a Master / Super Admin assign or move any Country Admin and a Global Admin only their own, refuses wrong roles and a no-op,
-- audits it; and salary_agency_map() then returns the whole chain with the app-facing IDs (Sub Admin, Country Admin, Global Admin).
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-0000000000a1', 'super@x'),
  ('b1000000-0000-0000-0000-0000000000b2', 'master@x'),
  ('c1000000-0000-0000-0000-0000000000c3', 'global1@x'),
  ('c2000000-0000-0000-0000-0000000000c4', 'global2@x'),
  ('d1000000-0000-0000-0000-0000000000d5', 'country_by_global@x'),
  ('d2000000-0000-0000-0000-0000000000d6', 'country_by_master@x'),
  ('d3000000-0000-0000-0000-0000000000d7', 'country_creator_gone@x'),
  ('e1000000-0000-0000-0000-0000000000e8', 'sub@x'),
  ('e2000000-0000-0000-0000-0000000000e9', 'plain@x'),
  ('f0000000-0000-0000-0000-0000000000f0', 'former_staff@x');   -- a person who created an account once but is not staff now
insert into public.staff_roles (user_id, role) values
  ('a1000000-0000-0000-0000-0000000000a1', 'super_admin'),
  ('b1000000-0000-0000-0000-0000000000b2', 'admin'),
  ('c1000000-0000-0000-0000-0000000000c3', 'global_admin'),
  ('c2000000-0000-0000-0000-0000000000c4', 'global_admin'),
  ('d1000000-0000-0000-0000-0000000000d5', 'country_admin'),
  ('d2000000-0000-0000-0000-0000000000d6', 'country_admin'),
  ('d3000000-0000-0000-0000-0000000000d7', 'country_admin');
insert into public.staff_roles (user_id, role, country_admin_id) values ('e1000000-0000-0000-0000-0000000000e8', 'sub_admin', 'd1000000-0000-0000-0000-0000000000d5');
-- the audit trail the back-fill reads: who created whom
insert into public.audit_logs (actor_id, action, target, severity) values
  ('c1000000-0000-0000-0000-0000000000c3', 'staff.created', 'd1000000-0000-0000-0000-0000000000d5 -> country_admin', 'warning'),
  ('b1000000-0000-0000-0000-0000000000b2', 'staff.created', 'd2000000-0000-0000-0000-0000000000d6 -> country_admin', 'warning'),
  ('f0000000-0000-0000-0000-0000000000f0', 'staff.created', 'd3000000-0000-0000-0000-0000000000d7 -> country_admin', 'warning');
-- (the inserts above fired the trigger, so clear the links and run the migration's own back-fill statement as it would have run at migration time)
update public.staff_roles set global_admin_id = null where role = 'country_admin';

update public.staff_roles s
   set global_admin_id = c.actor_id
  from (
    select distinct on (target_id) target_id, actor_id
      from (
        select a.actor_id, left(a.target, 36)::uuid as target_id, a.created_at
          from public.audit_logs a
         where a.action = 'staff.created'
           and a.actor_id is not null
           and a.target ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} -> country_admin$'
      ) x
     order by target_id, created_at desc
  ) c
 where s.user_id = c.target_id
   and s.role = 'country_admin'
   and s.global_admin_id is null
   and exists (select 1 from public.staff_roles g where g.user_id = c.actor_id and g.role = 'global_admin');

create or replace function pg_temp.as_user(p_id text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_id, false); $$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
create or replace function pg_temp.owner(p_id text) returns text language sql as $$
  select coalesce(left(global_admin_id::text, 2), 'none') from public.staff_roles where user_id = p_id::uuid;
$$;

-- 1. the back-fill
select '1 created by a Global Admin: linked (expect c1)' as check, pg_temp.owner('d1000000-0000-0000-0000-0000000000d5') as g;
select '1b created by a Master: not linked (expect none)' as check, pg_temp.owner('d2000000-0000-0000-0000-0000000000d6') as g;
select '1c creator no longer staff: not linked (expect none)' as check, pg_temp.owner('d3000000-0000-0000-0000-0000000000d7') as g;

-- 2. the trigger, for an account created from now on (what create_staff_account does last)
insert into auth.users (id, email) values ('d4000000-0000-0000-0000-0000000000da', 'new_country_by_global@x'), ('d5000000-0000-0000-0000-0000000000db', 'new_country_by_master@x');
insert into public.staff_roles (user_id, role) values ('d4000000-0000-0000-0000-0000000000da', 'country_admin'), ('d5000000-0000-0000-0000-0000000000db', 'country_admin');
insert into public.audit_logs (actor_id, action, target, severity) values ('c2000000-0000-0000-0000-0000000000c4', 'staff.created', 'd4000000-0000-0000-0000-0000000000da -> country_admin', 'warning');
insert into public.audit_logs (actor_id, action, target, severity) values ('b1000000-0000-0000-0000-0000000000b2', 'staff.created', 'd5000000-0000-0000-0000-0000000000db -> country_admin', 'warning');
select '2 a new Country Admin created by a Global Admin is linked to them (expect c2)' as check, pg_temp.owner('d4000000-0000-0000-0000-0000000000da') as g;
select '2b one created by a Master is not (expect none)' as check, pg_temp.owner('d5000000-0000-0000-0000-0000000000db') as g;
insert into public.audit_logs (actor_id, action, target, severity) values ('c2000000-0000-0000-0000-0000000000c4', 'staff.created', 'not a uuid -> country_admin', 'warning');
insert into public.audit_logs (actor_id, action, target, severity) values ('c2000000-0000-0000-0000-0000000000c4', 'staff.created', 'd1000000-0000-0000-0000-0000000000d5 -> sub_admin', 'warning');
select '2c a malformed or other-role audit row creates nothing and breaks nothing (expect c1 still)' as check, pg_temp.owner('d1000000-0000-0000-0000-0000000000d5') as g;
insert into public.audit_logs (actor_id, action, target, severity) values ('c2000000-0000-0000-0000-0000000000c4', 'staff.created', 'd1000000-0000-0000-0000-0000000000d5 -> country_admin', 'warning');
select '2d an already linked Country Admin is not taken over (expect c1)' as check, pg_temp.owner('d1000000-0000-0000-0000-0000000000d5') as g;

-- 3. transfer_country_admin
select pg_temp.as_user('e2000000-0000-0000-0000-0000000000e9');
select '3 a normal user is refused (expect t)' as check, pg_temp.refused('select public.transfer_country_admin(''d2000000-0000-0000-0000-0000000000d6'', ''c1000000-0000-0000-0000-0000000000c3'')', 'Only a Master%') as ok;
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');
select public.transfer_country_admin('d2000000-0000-0000-0000-0000000000d6', 'c1000000-0000-0000-0000-0000000000c3');
select '3b a Master assigns an unassigned Country Admin (expect c1)' as check, pg_temp.owner('d2000000-0000-0000-0000-0000000000d6') as g;
select public.transfer_country_admin('d2000000-0000-0000-0000-0000000000d6', 'c2000000-0000-0000-0000-0000000000c4');
select '3c ... and moves it to another Global Admin (expect c2)' as check, pg_temp.owner('d2000000-0000-0000-0000-0000000000d6') as g;
select '3d moving to the same Global Admin is refused (expect t)' as check, pg_temp.refused('select public.transfer_country_admin(''d2000000-0000-0000-0000-0000000000d6'', ''c2000000-0000-0000-0000-0000000000c4'')', 'That country admin already belongs%') as ok;
select '3e the target must be a Global Admin (expect t)' as check, pg_temp.refused('select public.transfer_country_admin(''d2000000-0000-0000-0000-0000000000d6'', ''b1000000-0000-0000-0000-0000000000b2'')', 'The receiving account is not a global admin') as ok;
select '3f the moved account must be a Country Admin (expect t)' as check, pg_temp.refused('select public.transfer_country_admin(''e1000000-0000-0000-0000-0000000000e8'', ''c1000000-0000-0000-0000-0000000000c3'')', 'That account is not a country admin') as ok;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select public.transfer_country_admin('d3000000-0000-0000-0000-0000000000d7', 'c1000000-0000-0000-0000-0000000000c3');
select '3g Super Admin can too (expect c1)' as check, pg_temp.owner('d3000000-0000-0000-0000-0000000000d7') as g;
-- a Global Admin: only their own
select pg_temp.as_user('c1000000-0000-0000-0000-0000000000c3');
select '3h a Global Admin cannot take or move someone else''s Country Admin (expect t)' as check, pg_temp.refused('select public.transfer_country_admin(''d2000000-0000-0000-0000-0000000000d6'', ''c1000000-0000-0000-0000-0000000000c3'')', 'That country admin is not one of yours') as ok;
select public.transfer_country_admin('d3000000-0000-0000-0000-0000000000d7', 'c2000000-0000-0000-0000-0000000000c4');
select '3i ... but can hand their own to another Global Admin (expect c2)' as check, pg_temp.owner('d3000000-0000-0000-0000-0000000000d7') as g;
select '3j transfers are audited (expect 4)' as check, count(*) as n from public.audit_logs where action = 'country_admin.transfer';

-- 4. the Salary export's chain: agency -> Sub Admin -> Country Admin -> Global Admin, with app IDs
insert into public.agencies (name, sub_admin_id) values ('Test agency', 'e1000000-0000-0000-0000-0000000000e8');
select pg_temp.as_user('b1000000-0000-0000-0000-0000000000b2');
select '4 the chain is complete with names and the app-facing IDs (expect true x6)' as check,
       sub_admin_name is not null as sub_name, sub_admin_display_id is not null as sub_id,
       country_admin_name is not null as country_name, country_admin_display_id is not null as country_id,
       global_admin_name is not null as global_name, global_admin_display_id is not null as global_id
  from public.salary_agency_map() where agency_name = 'Test agency';
select '4b the Global Admin of that chain is the owner of its Country Admin (expect true)' as check,
       global_admin_display_id = (select display_id from public.profiles where id = 'c1000000-0000-0000-0000-0000000000c3') as ok
  from public.salary_agency_map() where agency_name = 'Test agency';

-- 5. grants
select '5 anon cannot transfer, signed-in users can call it (the role is checked inside) (expect f, t)' as check,
       has_function_privilege('anon', 'public.transfer_country_admin(uuid,uuid)', 'execute') as anon,
       has_function_privilege('authenticated', 'public.transfer_country_admin(uuid,uuid)', 'execute') as authed;
select '5b the trigger function is not callable by app users (expect f, f)' as check,
       has_function_privilege('anon', 'public.link_new_country_admin_to_global()', 'execute') as anon,
       has_function_privilege('authenticated', 'public.link_new_country_admin_to_global()', 'execute') as authed;
