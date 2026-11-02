-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/staff_see_only_their_chain_test.sql
-- Proves (20261102100000): with the switch OFF every role sees exactly what it saw before; with it ON a Global / Country / Sub Admin / Agency account sees only
-- itself, the staff above it, its peers (Global / Country), everyone below it, the hosts and applicants of its agencies and the people named on its coin
-- transfers, in profiles, hosts, agencies, staff, wallets and coin transfers; Master, Super Admin and an ordinary app user still see everyone; the exact-ID
-- lookup reaches one person and nobody else; manages_agency is limited for a Global Admin; staff_emails is limited for a Global Admin.
--
-- The organisation:   S0 super   M0 master   G1 G2 global admins     C1 (under G1)  C2 (under G2)  C3 (under nobody)   S1 (under C1)  S2 (under C2)
--   A1 owned by S1, managed by M1;  A2 owned by S2, managed by M2;   hosts H1 (A1) H2 (A2) H3 (no agency);   AP1 applied to A1
--   users U1 (S1 sent coins), U2 (nobody dealt with), U3 (M1 sent coins), U4 (C2 sent coins);   S1 -> U1, M1 -> U3 (agency A1), C2 -> U4
insert into auth.users (id, email, raw_user_meta_data)
select v.id::uuid, v.email, jsonb_build_object('username', 'usr_' || split_part(v.email, '@', 1)) from (values
  ('00000000-0000-0000-0000-000000000001', 's0@x'), ('00000000-0000-0000-0000-000000000002', 'm0@x'),
  ('00000000-0000-0000-0000-000000000011', 'g1@x'), ('00000000-0000-0000-0000-000000000012', 'g2@x'),
  ('00000000-0000-0000-0000-000000000021', 'c1@x'), ('00000000-0000-0000-0000-000000000022', 'c2@x'), ('00000000-0000-0000-0000-000000000023', 'c3@x'),
  ('00000000-0000-0000-0000-000000000031', 's1@x'), ('00000000-0000-0000-0000-000000000032', 's2@x'),
  ('00000000-0000-0000-0000-000000000041', 'm1@x'), ('00000000-0000-0000-0000-000000000042', 'm2@x'),
  ('00000000-0000-0000-0000-000000000051', 'h1@x'), ('00000000-0000-0000-0000-000000000052', 'h2@x'), ('00000000-0000-0000-0000-000000000053', 'h3@x'),
  ('00000000-0000-0000-0000-000000000061', 'u1@x'), ('00000000-0000-0000-0000-000000000062', 'u2@x'), ('00000000-0000-0000-0000-000000000063', 'u3@x'),
  ('00000000-0000-0000-0000-000000000064', 'ap1@x'), ('00000000-0000-0000-0000-000000000065', 'u4@x')) v(id, email);
update public.profiles p set name = upper(split_part(u.email, '@', 1)), username = 'user_' || split_part(u.email, '@', 1) from auth.users u where u.id = p.id;

insert into public.agencies (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'A1'), ('aaaaaaaa-0000-0000-0000-000000000002', 'A2');
insert into public.staff_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000000001', 'super_admin'), ('00000000-0000-0000-0000-000000000002', 'admin'),
  ('00000000-0000-0000-0000-000000000011', 'global_admin'), ('00000000-0000-0000-0000-000000000012', 'global_admin');
insert into public.staff_roles (user_id, role, global_admin_id) values
  ('00000000-0000-0000-0000-000000000021', 'country_admin', '00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000022', 'country_admin', '00000000-0000-0000-0000-000000000012'),
  ('00000000-0000-0000-0000-000000000023', 'country_admin', null);
insert into public.staff_roles (user_id, role, country_admin_id) values
  ('00000000-0000-0000-0000-000000000031', 'sub_admin', '00000000-0000-0000-0000-000000000021'),
  ('00000000-0000-0000-0000-000000000032', 'sub_admin', '00000000-0000-0000-0000-000000000022');
update public.agencies set sub_admin_id = '00000000-0000-0000-0000-000000000031', manager_id = '00000000-0000-0000-0000-000000000041' where name = 'A1';
update public.agencies set sub_admin_id = '00000000-0000-0000-0000-000000000032', manager_id = '00000000-0000-0000-0000-000000000042' where name = 'A2';
insert into public.staff_roles (user_id, role, agency_id) values
  ('00000000-0000-0000-0000-000000000041', 'agency_manager', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000042', 'agency_manager', 'aaaaaaaa-0000-0000-0000-000000000002');
insert into public.host_profiles (profile_id, agency_id) values
  ('00000000-0000-0000-0000-000000000051', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000052', 'aaaaaaaa-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000053', null);
insert into public.host_applications (applicant_id, agency_id) values ('00000000-0000-0000-0000-000000000064', 'aaaaaaaa-0000-0000-0000-000000000001');
insert into public.coin_transfers (sender_id, recipient_id, coins, recipient_kind, agency_id) values
  ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000061', 10, 'user', null),
  ('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000063', 10, 'user', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000065', 10, 'user', null);
update public.wallets set coins = 100;
create table public.t_ids as select name, display_id from public.profiles;   -- display IDs read as the owner (a ghost is hidden from everyone else)

-- helpers (public, so the restricted test role can run them)
create function public.t_who(p_sub text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_sub, false) $$;
-- only the Super Admin can change the release switches (a guard trigger), so the helper acts as one for that single statement and then restores the caller
create function public.t_set_switch(p_on boolean) returns void language plpgsql security definer as $$
declare v_was text := current_setting('request.jwt.claim.sub', true);
begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
  update public.app_config set feature_flags = case when p_on then feature_flags || '{"limit_staff_to_own_chain": true}'::jsonb else feature_flags - 'limit_staff_to_own_chain' end where id;
  perform set_config('request.jwt.claim.sub', coalesce(v_was, ''), false);
end $$;
create function public.t_names(p_sql text) returns text language plpgsql as $$
declare r text; begin execute 'select coalesce(string_agg(n, '','' order by n), ''-'') from (' || p_sql || ') q(n)' into r; return r; end $$;
create function public.t_profiles() returns text language sql as $$ select public.t_names('select name from public.profiles') $$;
create function public.t_hosts() returns text language sql as $$ select public.t_names('select p.name from public.host_profiles h join public.profiles p on p.id = h.profile_id') $$;
create function public.t_agencies() returns text language sql as $$ select public.t_names('select name from public.agencies') $$;
create function public.t_staff() returns text language sql as $$ select public.t_names('select p.name from public.staff_roles s join public.profiles p on p.id = s.user_id') $$;
create function public.t_wallets() returns text language sql as $$ select public.t_names('select p.name from public.wallets w join public.profiles p on p.id = w.profile_id') $$;
create function public.t_transfers() returns text language sql as $$ select public.t_names('select count(*)::text from public.coin_transfers') $$;
grant execute on all functions in schema public to authenticated;

-- ==== A. switch OFF: everybody sees everything they saw before ====
select public.t_set_switch(false);
set role authenticated;
select public.t_who('00000000-0000-0000-0000-000000000011');
select 'A1 switch off: Global G1 sees all 19 people (expect 19)' as check, length(public.t_profiles()) - length(replace(public.t_profiles(), ',', '')) + 1 as n;
select 'A2 switch off: Country C1 sees all hosts (expect H1,H2,H3)' as check, public.t_hosts() as seen;
select public.t_who('00000000-0000-0000-0000-000000000031');
select 'A3 switch off: Sub Admin S1 sees both agencies (expect A1,A2)' as check, public.t_agencies() as seen;
reset role;
select public.t_who('00000000-0000-0000-0000-000000000011');
set role authenticated;
select 'A5 switch off: Global G1 manages A2 (expect t)' as check, public.manages_agency('aaaaaaaa-0000-0000-0000-000000000002') as ok;
reset role;

-- ==== B. switch ON ====
select public.t_set_switch(true);
set role authenticated;

select public.t_who('00000000-0000-0000-0000-000000000011');   -- G1
select 'B1 Global G1 profiles' as check, public.t_profiles() as seen;       -- expect AP1,C1,G1,G2,H1,M1,S1,U1,U3  (G2 is a peer)
select 'B2 Global G1 hosts (expect H1)' as check, public.t_hosts() as seen;
select 'B3 Global G1 agencies (expect A1)' as check, public.t_agencies() as seen;
select 'B4 Global G1 staff (expect C1,G1,G2,M1,S1)' as check, public.t_staff() as seen;
select 'B5 Global G1 wallets (expect AP1,C1,G1,H1,M1,S1,U1,U3: not the peer G2)' as check, public.t_wallets() as seen;
select 'B6 Global G1 coin transfers (expect 2: S1->U1 and M1->U3, not C2->U4)' as check, public.t_transfers() as seen;
select 'B7 Global G1 manages A1 (t) and A2 (f)' as check, public.manages_agency('aaaaaaaa-0000-0000-0000-000000000001') as a1, public.manages_agency('aaaaaaaa-0000-0000-0000-000000000002') as a2;
select 'B8 Global G1 in_country_scope A1 (t) and A2 (f)' as check, public.in_country_scope_agency('aaaaaaaa-0000-0000-0000-000000000001') as a1, public.in_country_scope_agency('aaaaaaaa-0000-0000-0000-000000000002') as a2;
select 'B9 Global G1 staff_emails: own chain only (expect 2: c1, s1; not c2/c3/s2)' as check,
  (select count(*) from public.staff_emails(array['00000000-0000-0000-0000-000000000021','00000000-0000-0000-0000-000000000031','00000000-0000-0000-0000-000000000022','00000000-0000-0000-0000-000000000023','00000000-0000-0000-0000-000000000032']::uuid[])) as n;

select public.t_who('00000000-0000-0000-0000-000000000021');   -- C1
select 'B10 Country C1 profiles' as check, public.t_profiles() as seen;     -- expect AP1,C1,C2,C3,G1,H1,M1,S1,U1,U3
select 'B11 Country C1 hosts (expect H1)' as check, public.t_hosts() as seen;
select 'B12 Country C1 agencies (expect A1)' as check, public.t_agencies() as seen;
select 'B13 Country C1 staff (expect C1,C2,C3,G1,M1,S1)' as check, public.t_staff() as seen;
select 'B14 Country C1 coin transfers (expect 2)' as check, public.t_transfers() as seen;

select public.t_who('00000000-0000-0000-0000-000000000023');   -- C3 has no Global Admin and no sub admins
select 'B15 Country C3 (nothing under them) sees only itself and its peers (expect C1,C2,C3)' as check, public.t_profiles() as seen;
select 'B16 Country C3 hosts and agencies (expect - and -)' as check, public.t_hosts() as hosts, public.t_agencies() as agencies;

select public.t_who('00000000-0000-0000-0000-000000000031');   -- S1
select 'B17 Sub Admin S1 profiles' as check, public.t_profiles() as seen;    -- expect AP1,C1,H1,M1,S1,U1,U3
select 'B18 Sub Admin S1 hosts (expect H1)' as check, public.t_hosts() as seen;
select 'B19 Sub Admin S1 agencies (expect A1)' as check, public.t_agencies() as seen;
select 'B20 Sub Admin S1 staff (expect C1,M1,S1)' as check, public.t_staff() as seen;

select public.t_who('00000000-0000-0000-0000-000000000041');   -- M1 (agency)
select 'B21 Agency M1 profiles' as check, public.t_profiles() as seen;       -- expect AP1,H1,M1,S1,U3
select 'B22 Agency M1 hosts (expect H1)' as check, public.t_hosts() as seen;
select 'B23 Agency M1 agencies (expect A1)' as check, public.t_agencies() as seen;

select public.t_who('00000000-0000-0000-0000-000000000042');   -- M2 (agency) sees nothing of A1
select 'B24 Agency M2 profiles (expect H2,M2,S2)' as check, public.t_profiles() as seen;

-- ==== C. everyone else is untouched ====
select public.t_who('00000000-0000-0000-0000-000000000002');   -- Master
select 'C1 Master sees all 19 (expect 19)' as check, length(public.t_profiles()) - length(replace(public.t_profiles(), ',', '')) + 1 as n;
select 'C2 Master sees all 3 hosts (expect H1,H2,H3)' as check, public.t_hosts() as seen;
select public.t_who('00000000-0000-0000-0000-000000000001');   -- Super Admin
select 'C3 Super Admin sees all 19 (expect 19)' as check, length(public.t_profiles()) - length(replace(public.t_profiles(), ',', '')) + 1 as n;
select public.t_who('00000000-0000-0000-0000-000000000062');   -- an ordinary app user
select 'C4 an ordinary app user still sees all 19 profiles and all hosts (expect 19 and H1,H2,H3)' as check,
  length(public.t_profiles()) - length(replace(public.t_profiles(), ',', '')) + 1 as n, public.t_hosts() as hosts;
select 'C5 an ordinary app user sees only their own wallet row as before is NOT changed by this migration (wallet policies untouched): rows seen' as check, public.t_wallets() as seen;
reset role;

-- ==== D. the exact-ID lookup ====
select public.t_who('00000000-0000-0000-0000-000000000021');
set role authenticated;
select 'D1 Country C1 finds an ordinary user by exact ID (expect U2)' as check, (select name from public.find_user_for_coins((select display_id from public.t_ids where name = 'U2'))) as found;
select 'D2 ...and that user is still not in C1''s lists (expect -)' as check, public.t_names('select name from public.profiles where name = ''U2''') as seen;
select public.t_who('00000000-0000-0000-0000-000000000062');
select 'D3 an ordinary app user cannot use the lookup (expect 0 rows)' as check, (select count(*) from public.find_user_for_coins((select display_id from public.t_ids where name = 'U1'))) as n;
reset role;
update public.profiles set is_ghost = true where name = 'U2';
select public.t_who('00000000-0000-0000-0000-000000000002');
set role authenticated;
select 'D4 a ghost account is never found (expect 0)' as check, (select count(*) from public.find_user_for_coins((select display_id from public.t_ids where name = 'U2'))) as n;
reset role;

-- ==== E. switching it off again restores everything at once ====
select public.t_set_switch(false);
select public.t_who('00000000-0000-0000-0000-000000000011');
set role authenticated;
select 'E1 switch off again: Global G1 sees the other agency again (expect A1,A2)' as check, public.t_agencies() as seen;
reset role;
