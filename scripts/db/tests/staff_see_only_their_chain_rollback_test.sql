-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/staff_see_only_their_chain_rollback_test.sql
-- Proves supabase/rollbacks/20261102100000_down.sql: with the switch ON, a Global Admin sees only its chain; after the rollback the policies and helpers are gone,
-- the three function bodies are the old ones (a Global Admin sees the whole tree, whatever the switch says), a second run is harmless, and the migration applies again.
insert into auth.users (id, email, raw_user_meta_data) select v.id::uuid, v.email, jsonb_build_object('username', 'usr_' || split_part(v.email, '@', 1))
  from (values ('00000000-0000-0000-0000-000000000001', 's0@x'), ('00000000-0000-0000-0000-000000000011', 'g1@x'), ('00000000-0000-0000-0000-000000000021', 'c1@x'),
               ('00000000-0000-0000-0000-000000000031', 's1@x'), ('00000000-0000-0000-0000-000000000032', 's2@x')) v(id, email);
insert into public.staff_roles (user_id, role) values ('00000000-0000-0000-0000-000000000001', 'super_admin'), ('00000000-0000-0000-0000-000000000011', 'global_admin');
insert into public.staff_roles (user_id, role, global_admin_id) values ('00000000-0000-0000-0000-000000000021', 'country_admin', '00000000-0000-0000-0000-000000000011');
insert into public.staff_roles (user_id, role, country_admin_id) values ('00000000-0000-0000-0000-000000000031', 'sub_admin', '00000000-0000-0000-0000-000000000021'), ('00000000-0000-0000-0000-000000000032', 'sub_admin', null);
insert into public.agencies (id, name, sub_admin_id) values ('aaaaaaaa-0000-0000-0000-000000000001', 'A1', '00000000-0000-0000-0000-000000000031'), ('aaaaaaaa-0000-0000-0000-000000000002', 'A2', '00000000-0000-0000-0000-000000000032');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
update public.app_config set feature_flags = feature_flags || '{"limit_staff_to_own_chain": true}'::jsonb where id;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', false);

select '1 before: the switch is on, Global G1 manages A1 and not A2 (expect t, f)' as check,
  public.manages_agency('aaaaaaaa-0000-0000-0000-000000000001') as a1, public.manages_agency('aaaaaaaa-0000-0000-0000-000000000002') as a2;
select '1b before: 6 restrictive policies and 9 new functions exist (expect 6, 9)' as check,
  (select count(*) from pg_policies where policyname = 'Scoped staff see their own chain') as policies,
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('staff_scope_limited','staff_scope_applies','global_owns_agency','staff_managed_agency_ids','staff_downline_ids','staff_visible_staff_ids','staff_chain_profile_ids','staff_visible_profile_ids','find_user_for_coins')) as funcs;

\i supabase/rollbacks/20261102100000_down.sql
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', false);
select '2 after: no policy and no helper left (expect 0, 0)' as check,
  (select count(*) from pg_policies where policyname = 'Scoped staff see their own chain') as policies,
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('staff_scope_limited','staff_scope_applies','global_owns_agency','staff_managed_agency_ids','staff_downline_ids','staff_visible_staff_ids','staff_chain_profile_ids','staff_visible_profile_ids','find_user_for_coins')) as funcs;
select '3 after: Global G1 manages every agency again, the switch is ignored (expect t, t)' as check,
  public.manages_agency('aaaaaaaa-0000-0000-0000-000000000001') as a1, public.manages_agency('aaaaaaaa-0000-0000-0000-000000000002') as a2;
select '4 after: in_country_scope_agency is the old one (expect t, t)' as check,
  public.in_country_scope_agency('aaaaaaaa-0000-0000-0000-000000000001') as a1, public.in_country_scope_agency('aaaaaaaa-0000-0000-0000-000000000002') as a2;
select '5 after: profiles read normally for a Global Admin (expect 5)' as check, count(*) as n from public.profiles;

\i supabase/rollbacks/20261102100000_down.sql
select '6 a second run of the rollback is harmless (reached here)' as check;

\i supabase/migrations/20261102100000_staff_see_only_their_chain.sql
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', false);
select '7 the migration applies again and the rule is back (expect t, f)' as check,
  public.manages_agency('aaaaaaaa-0000-0000-0000-000000000001') as a1, public.manages_agency('aaaaaaaa-0000-0000-0000-000000000002') as a2;
