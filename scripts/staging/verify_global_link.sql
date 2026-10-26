-- Exercises the Country Admin -> Global Admin link (20261026100000) on STAGING with the real grants, then rolls back. Run through scripts/staging/verify_global_link.sh.
-- Staging only has a Super Admin and a Master, so it builds its own Global / Country / Sub Admins and an agency inside the transaction. Safe: ends in ROLLBACK.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

do $$
declare
  g1 uuid := gen_random_uuid(); g2 uuid := gen_random_uuid(); c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid(); plain uuid := gen_random_uuid();
  staff uuid := (select user_id from public.staff_roles where role = 'super_admin' order by user_id limit 1);
begin
  if staff is null then
    insert into res(step, ok, info) values ('setup: a Super Admin exists on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  insert into auth.users (id, aud, role, email, raw_user_meta_data) values
    (g1, 'authenticated', 'authenticated', 'zz-smoke-g1@staging.sabalive.test', '{"name":"ZZ Global One"}'),
    (g2, 'authenticated', 'authenticated', 'zz-smoke-g2@staging.sabalive.test', '{"name":"ZZ Global Two"}'),
    (c1, 'authenticated', 'authenticated', 'zz-smoke-c1@staging.sabalive.test', '{"name":"ZZ Country One"}'),
    (c2, 'authenticated', 'authenticated', 'zz-smoke-c2@staging.sabalive.test', '{"name":"ZZ Country Two"}'),
    (s1, 'authenticated', 'authenticated', 'zz-smoke-s1@staging.sabalive.test', '{"name":"ZZ Sub One"}'),
    (plain, 'authenticated', 'authenticated', 'zz-smoke-plain@staging.sabalive.test', '{"name":"ZZ Plain"}');
  insert into public.staff_roles (user_id, role) values (g1, 'global_admin'), (g2, 'global_admin'), (c1, 'country_admin'), (c2, 'country_admin');
  insert into public.staff_roles (user_id, role, country_admin_id) values (s1, 'sub_admin', c1);
  insert into public.agencies (name, sub_admin_id) values ('ZZ smoke agency', s1);
  insert into ids values ('staff', staff::text), ('g1', g1::text), ('g2', g2::text), ('c1', c1::text), ('c2', c2::text), ('plain', plain::text);
end
$$;

set local role authenticated;
do $$
declare
  staff uuid := (select val::uuid from ids where k = 'staff');
  g1 uuid := (select val::uuid from ids where k = 'g1');
  g2 uuid := (select val::uuid from ids where k = 'g2');
  c1 uuid := (select val::uuid from ids where k = 'c1');
  m record;
begin
  if staff is null then return; end if;
  perform set_config('request.jwt.claim.sub', staff::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', staff), true);

  select * into m from public.salary_agency_map() where agency_name = 'ZZ smoke agency';
  insert into res(step, ok, info) values ('1 the new chain: Sub and Country Admin are named with their User IDs, the Global Admin is not assigned yet',
    m.sub_admin_name = 'ZZ Sub One' and m.sub_admin_display_id is not null and m.country_admin_name = 'ZZ Country One' and m.country_admin_display_id is not null and m.global_admin_name is null,
    coalesce(m.sub_admin_name, '-') || ' / ' || coalesce(m.country_admin_name, '-') || ' / ' || coalesce(m.global_admin_name, 'no global'));

  begin
    perform public.transfer_country_admin(c1, g1);
    select * into m from public.salary_agency_map() where agency_name = 'ZZ smoke agency';
    insert into res(step, ok, info) values ('2 the Super Admin assigns the Country Admin to a Global Admin and the chain shows that Global Admin by name and User ID',
      m.global_admin_name = 'ZZ Global One' and m.global_admin_display_id = (select display_id from public.profiles where id = g1), coalesce(m.global_admin_name, '-') || ' #' || coalesce(m.global_admin_display_id::text, '-'));
  exception when others then insert into res(step, ok, info) values ('2 assign', false, sqlerrm); end;

  begin
    perform public.transfer_country_admin(c1, g2);
    select * into m from public.salary_agency_map() where agency_name = 'ZZ smoke agency';
    insert into res(step, ok, info) values ('3 moved to another Global Admin: the chain follows', m.global_admin_name = 'ZZ Global Two', coalesce(m.global_admin_name, '-'));
  exception when others then insert into res(step, ok, info) values ('3 move', false, sqlerrm); end;

  begin
    perform public.transfer_country_admin(c1, g2);
    insert into res(step, ok, info) values ('4 moving to the same Global Admin is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('4 moving to the same Global Admin is refused', sqlerrm like '%already belongs%', sqlerrm); end;

  begin
    perform public.transfer_country_admin(c1, c1);
    insert into res(step, ok, info) values ('5 the receiver must be a Global Admin', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('5 the receiver must be a Global Admin', sqlerrm like '%not a global admin%', sqlerrm); end;
end
$$;
reset role;

-- a Global Admin may move only their own Country Admin
set local role authenticated;
do $$
declare
  g1 uuid := (select val::uuid from ids where k = 'g1');
  g2 uuid := (select val::uuid from ids where k = 'g2');
  c1 uuid := (select val::uuid from ids where k = 'c1');
begin
  if g1 is null then return; end if;
  perform set_config('request.jwt.claim.sub', g1::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g1), true);
  begin
    perform public.transfer_country_admin(c1, g1);
    insert into res(step, ok, info) values ('6 a Global Admin cannot take a Country Admin of another Global Admin', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('6 a Global Admin cannot take a Country Admin of another Global Admin', sqlerrm like '%not one of yours%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', g2::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', g2), true);
  begin
    perform public.transfer_country_admin(c1, g1);
    insert into res(step, ok, info) values ('6b ... but can hand their own to another Global Admin', (select global_admin_id from public.staff_roles where user_id = c1) = g1, '');
  exception when others then insert into res(step, ok, info) values ('6b hand over their own', false, sqlerrm); end;
end
$$;
reset role;

-- an ordinary user and anon
set local role authenticated;
do $$
declare
  plain uuid := (select val::uuid from ids where k = 'plain');
  c1 uuid := (select val::uuid from ids where k = 'c1');
  g1 uuid := (select val::uuid from ids where k = 'g1');
begin
  if plain is null then return; end if;
  perform set_config('request.jwt.claim.sub', plain::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', plain), true);
  begin
    perform public.transfer_country_admin(c1, g1);
    insert into res(step, ok, info) values ('7 an ordinary user cannot transfer', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('7 an ordinary user cannot transfer', true, sqlerrm); end;
end
$$;
reset role;
insert into res(step, ok, info)
  select '8 the anon role cannot call it', not has_function_privilege('anon', 'public.transfer_country_admin(uuid,uuid)', 'execute'), null;

-- the trigger: a Country Admin created from now on by a Global Admin is linked to them (the audit row create_staff_account writes)
insert into public.audit_logs (actor_id, action, target, severity)
  select (select val::uuid from ids where k = 'g2'), 'staff.created', (select val from ids where k = 'c2') || ' -> country_admin', 'warning'
   where exists (select 1 from ids where k = 'c2');
insert into res(step, ok, info)
  select '9 a Country Admin created by a Global Admin is linked to them at once', s.global_admin_id = (select val::uuid from ids where k = 'g2'), ''
    from public.staff_roles s where s.user_id = (select val::uuid from ids where k = 'c2');

select n, step, ok, info from res order by n;

rollback;
