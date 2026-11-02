-- Exercises "each admin sees only their own chain" (20261102100000) on STAGING with the real grants, then rolls back. Run through scripts/staging/verify_staff_scope.sh.
-- It builds a small organisation of its own (two Global Admins, two Country Admins, two Sub Admins, two agencies with managers and hosts, buyers and a coin transfer)
-- inside the transaction, turns the switch ON inside it too, and checks what every role sees, including the real fake accounts already on staging. Ends in ROLLBACK.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

create function public.zz_as(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, true), set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p), true) $$;
create function public.zz_seen(p_sql text) returns text language plpgsql as $$
declare r text; begin execute 'select coalesce(string_agg(n, '','' order by n), ''-'') from (' || p_sql || ') q(n)' into r; return r; end $$;
grant execute on function public.zz_as(uuid), public.zz_seen(text) to public;

do $$
declare
  g1 uuid := gen_random_uuid(); g2 uuid := gen_random_uuid(); c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); m1 uuid := gen_random_uuid(); m2 uuid := gen_random_uuid();
  h1 uuid := gen_random_uuid(); h2 uuid := gen_random_uuid(); u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  staff uuid := (select user_id from public.staff_roles where role = 'super_admin' order by user_id limit 1);
  master uuid := (select user_id from public.staff_roles where role = 'admin' order by user_id limit 1);
  appuser uuid := (select id from auth.users where email = 'user1@staging.sabalive.test');
begin
  if staff is null then
    insert into res(step, ok, info) values ('setup: a Super Admin exists on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  insert into auth.users (id, aud, role, email, raw_user_meta_data) values
    (g1, 'authenticated', 'authenticated', 'zz-smoke-sc-g1@staging.sabalive.test', '{"name":"ZZ Global One","username":"zz_sc_g1"}'),
    (g2, 'authenticated', 'authenticated', 'zz-smoke-sc-g2@staging.sabalive.test', '{"name":"ZZ Global Two","username":"zz_sc_g2"}'),
    (c1, 'authenticated', 'authenticated', 'zz-smoke-sc-c1@staging.sabalive.test', '{"name":"ZZ Country One","username":"zz_sc_c1"}'),
    (c2, 'authenticated', 'authenticated', 'zz-smoke-sc-c2@staging.sabalive.test', '{"name":"ZZ Country Two","username":"zz_sc_c2"}'),
    (s1, 'authenticated', 'authenticated', 'zz-smoke-sc-s1@staging.sabalive.test', '{"name":"ZZ Sub One","username":"zz_sc_s1"}'),
    (s2, 'authenticated', 'authenticated', 'zz-smoke-sc-s2@staging.sabalive.test', '{"name":"ZZ Sub Two","username":"zz_sc_s2"}'),
    (m1, 'authenticated', 'authenticated', 'zz-smoke-sc-m1@staging.sabalive.test', '{"name":"ZZ Agency One","username":"zz_sc_m1"}'),
    (m2, 'authenticated', 'authenticated', 'zz-smoke-sc-m2@staging.sabalive.test', '{"name":"ZZ Agency Two","username":"zz_sc_m2"}'),
    (h1, 'authenticated', 'authenticated', 'zz-smoke-sc-h1@staging.sabalive.test', '{"name":"ZZ Host One","username":"zz_sc_h1"}'),
    (h2, 'authenticated', 'authenticated', 'zz-smoke-sc-h2@staging.sabalive.test', '{"name":"ZZ Host Two","username":"zz_sc_h2"}'),
    (u1, 'authenticated', 'authenticated', 'zz-smoke-sc-u1@staging.sabalive.test', '{"name":"ZZ Buyer One","username":"zz_sc_u1"}'),
    (u2, 'authenticated', 'authenticated', 'zz-smoke-sc-u2@staging.sabalive.test', '{"name":"ZZ Stranger","username":"zz_sc_u2"}');
  insert into public.staff_roles (user_id, role) values (g1, 'global_admin'), (g2, 'global_admin');
  insert into public.staff_roles (user_id, role, global_admin_id) values (c1, 'country_admin', g1), (c2, 'country_admin', g2);
  insert into public.staff_roles (user_id, role, country_admin_id) values (s1, 'sub_admin', c1), (s2, 'sub_admin', c2);
  insert into public.agencies (id, name, sub_admin_id, manager_id) values (a1, 'ZZ scope agency one', s1, m1), (a2, 'ZZ scope agency two', s2, m2);
  insert into public.staff_roles (user_id, role, agency_id) values (m1, 'agency_manager', a1), (m2, 'agency_manager', a2);
  insert into public.host_profiles (profile_id, agency_id) values (h1, a1), (h2, a2);
  insert into public.coin_transfers (sender_id, recipient_id, coins, recipient_kind) values (s1, u1, 5, 'user');
  insert into ids values ('staff', staff::text), ('master', coalesce(master::text, '')), ('appuser', coalesce(appuser::text, '')),
    ('g1', g1::text), ('g2', g2::text), ('c1', c1::text), ('c2', c2::text), ('s1', s1::text), ('s2', s2::text), ('m1', m1::text), ('m2', m2::text), ('u2', u2::text),
    ('u2_did', (select display_id::text from public.profiles where id = u2)),
    -- Global Admin accounts that already exist on staging are peers of the test Global Admin: the rule shows peers of the same rank, so they are expected
    ('real_globals', (select coalesce(string_agg(user_id::text, ','), '') from public.staff_roles where role = 'global_admin' and user_id not in (g1, g2)));
end
$$;

-- the Super Admin turns the switch on (the release controls are Super Admin only)
select public.zz_as((select val::uuid from ids where k = 'staff'));
update public.app_config set feature_flags = feature_flags || '{"limit_staff_to_own_chain": false}'::jsonb where id;

set local role authenticated;
do $$
declare
  staff uuid := (select val::uuid from ids where k = 'staff');
  master uuid := nullif((select val from ids where k = 'master'), '')::uuid;
  appuser uuid := nullif((select val from ids where k = 'appuser'), '')::uuid;
  g1 uuid := (select val::uuid from ids where k = 'g1');
  c1 uuid := (select val::uuid from ids where k = 'c1');
  c2 uuid := (select val::uuid from ids where k = 'c2');
  s1 uuid := (select val::uuid from ids where k = 's1');
  m1 uuid := (select val::uuid from ids where k = 'm1');
  u2 uuid := (select val::uuid from ids where k = 'u2');
  total bigint; n bigint; seen text;
begin
  if staff is null then return; end if;
  perform public.zz_as(staff);
  select count(*) into total from public.profiles;

  -- A. switch OFF (it is off by default): nothing changed for anybody
  perform public.zz_as(g1);
  select count(*) into n from public.profiles;
  insert into res(step, ok, info) values ('A1 switch off: a Global Admin still sees every profile', n = total, n || ' of ' || total);
  insert into res(step, ok, info) values ('A2 switch off: a Global Admin still manages both agencies',
    public.manages_agency((select id from public.agencies where name = 'ZZ scope agency two')) and public.manages_agency((select id from public.agencies where name = 'ZZ scope agency one')), '');
  perform public.zz_as(c1);
  select count(*) into n from public.agencies;
  insert into res(step, ok, info) values ('A3 switch off: a Country Admin still lists every agency', n >= 2, n::text);
end
$$;

-- turn it on
reset role;
select public.zz_as((select val::uuid from ids where k = 'staff'));
update public.app_config set feature_flags = feature_flags || '{"limit_staff_to_own_chain": true}'::jsonb where id;
set local role authenticated;

do $$
declare
  staff uuid := (select val::uuid from ids where k = 'staff');
  master uuid := nullif((select val from ids where k = 'master'), '')::uuid;
  appuser uuid := nullif((select val from ids where k = 'appuser'), '')::uuid;
  g1 uuid := (select val::uuid from ids where k = 'g1');
  c1 uuid := (select val::uuid from ids where k = 'c1');
  s1 uuid := (select val::uuid from ids where k = 's1');
  m1 uuid := (select val::uuid from ids where k = 'm1');
  m2 uuid := (select val::uuid from ids where k = 'm2');
  u2 uuid := (select val::uuid from ids where k = 'u2');
  total bigint; n bigint; seen text;
begin
  perform public.zz_as(staff);
  select count(*) into total from public.profiles;

  -- B. switch ON
  perform public.zz_as(g1);
  seen := public.zz_seen('select name from public.profiles where id::text <> all(string_to_array((select val from ids where k = ''real_globals''), '',''))');
  insert into res(step, ok, info) values ('B1 Global Admin sees its own chain and its peers and nothing else (no real staging account, no other chain)',
    seen = 'ZZ Agency One,ZZ Buyer One,ZZ Country One,ZZ Global One,ZZ Global Two,ZZ Host One,ZZ Sub One', seen);
  seen := public.zz_seen('select name from public.agencies');
  insert into res(step, ok, info) values ('B2 ... only its agency', seen = 'ZZ scope agency one', seen);
  seen := public.zz_seen('select p.name from public.host_profiles h join public.profiles p on p.id = h.profile_id');
  insert into res(step, ok, info) values ('B3 ... only its host', seen = 'ZZ Host One', seen);
  select count(*) into n from public.wallets;
  insert into res(step, ok, info) values ('B4 ... and only the wallets of its chain (6: itself, country, sub, agency, host, buyer; the peer is not one)', n = 6, n::text);
  insert into res(step, ok, info) values ('B5 ... manages its agency and not the other',
    public.manages_agency((select id from public.agencies where name = 'ZZ scope agency one')) and not public.manages_agency((select id from public.agencies where name = 'ZZ scope agency two')), '');

  perform public.zz_as(c1);
  seen := public.zz_seen('select name from public.profiles');
  insert into res(step, ok, info) values ('B6 Country Admin sees its Sub Admin tree, its Global Admin and its peer',
    seen = 'ZZ Agency One,ZZ Buyer One,ZZ Country One,ZZ Country Two,ZZ Global One,ZZ Host One,ZZ Sub One', seen);

  perform public.zz_as(s1);
  seen := public.zz_seen('select name from public.profiles');
  insert into res(step, ok, info) values ('B7 Sub Admin sees its agency, host, buyer and the Country Admin above it',
    seen = 'ZZ Agency One,ZZ Buyer One,ZZ Country One,ZZ Host One,ZZ Sub One', seen);

  perform public.zz_as(m1);
  seen := public.zz_seen('select name from public.profiles');
  insert into res(step, ok, info) values ('B8 Agency sees itself, its host and its Sub Admin', seen = 'ZZ Agency One,ZZ Host One,ZZ Sub One', seen);

  perform public.zz_as(m2);
  seen := public.zz_seen('select name from public.profiles');
  insert into res(step, ok, info) values ('B9 the other agency sees nothing of the first chain', seen = 'ZZ Agency Two,ZZ Host Two,ZZ Sub Two', seen);

  perform public.zz_as(c1);
  select count(*) into n from public.find_user_for_coins((select val::bigint from ids where k = 'u2_did'));
  insert into res(step, ok, info) values ('B10 a Country Admin can still reach one ordinary person by exact User ID', n = 1, n::text);
  insert into res(step, ok, info) values ('B11 ... who stays out of its lists', not exists (select 1 from public.profiles where id = u2), '');

  -- C. everybody else is untouched
  perform public.zz_as(staff);
  select count(*) into n from public.profiles;
  insert into res(step, ok, info) values ('C1 Super Admin still sees everyone', n = total, n || ' of ' || total);
  if master is not null then
    perform public.zz_as(master);
    select count(*) into n from public.profiles;
    insert into res(step, ok, info) values ('C2 Master still sees everyone', n = total, n || ' of ' || total);
  end if;
  if appuser is not null then
    perform public.zz_as(appuser);
    select count(*) into n from public.profiles;
    insert into res(step, ok, info) values ('C3 a real app account on staging still sees every profile and every host', n = total and (select count(*) from public.host_profiles) >= 2, n || ' of ' || total);
  end if;
end
$$;

select n, step, ok, info from res order by n;

rollback;
