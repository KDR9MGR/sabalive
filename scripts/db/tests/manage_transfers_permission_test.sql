-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/manage_transfers_permission_test.sql
-- Proves (20261114100000): a Super Admin and a Master can switch `manage_transfers` on and off for a Global / Country / Sub Admin; a Global Admin cannot give it; a misspelt key is refused; the
-- other permissions still work (view_all_users, pull_back_coins); and the switch is stored as a plain permission (so the panel's Access Control can read it back).
insert into auth.users (id, email, raw_user_meta_data)
select v.id::uuid, v.email, jsonb_build_object('username', 'usr_' || split_part(v.email, '@', 1)) from (values
  ('00000000-0000-0000-0000-000000000001', 's0@x'), ('00000000-0000-0000-0000-000000000002', 'm0@x'),
  ('00000000-0000-0000-0000-000000000011', 'g1@x'), ('00000000-0000-0000-0000-000000000021', 'c1@x'), ('00000000-0000-0000-0000-000000000031', 's1@x')) v(id, email);
insert into public.staff_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000000001', 'super_admin'), ('00000000-0000-0000-0000-000000000002', 'admin'), ('00000000-0000-0000-0000-000000000011', 'global_admin');
insert into public.staff_roles (user_id, role, global_admin_id) values ('00000000-0000-0000-0000-000000000021', 'country_admin', '00000000-0000-0000-0000-000000000011');
insert into public.staff_roles (user_id, role, country_admin_id) values ('00000000-0000-0000-0000-000000000031', 'sub_admin', '00000000-0000-0000-0000-000000000021');

create function public.t_who(p_sub text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_sub, false) $$;
create temp table r (n serial, check_name text, ok boolean);
grant all on r to authenticated;
grant usage, select on sequence r_n_seq to authenticated;
grant execute on function public.t_who(text) to authenticated;
set role authenticated;

select public.t_who('00000000-0000-0000-0000-000000000001');   -- Super Admin
select public.set_staff_permissions('00000000-0000-0000-0000-000000000021', '{"manage_transfers": true}'::jsonb);
reset role;
insert into r(check_name, ok) select '1 a Super Admin switches manage_transfers on for a Country Admin (stored as true)', (select permissions ->> 'manage_transfers' = 'true' from public.staff_roles where user_id = '00000000-0000-0000-0000-000000000021');
set role authenticated;

select public.t_who('00000000-0000-0000-0000-000000000002');   -- Master
select public.set_staff_permissions('00000000-0000-0000-0000-000000000011', '{"manage_transfers": true, "view_all_users": true, "pull_back_coins": true}'::jsonb);
reset role;
insert into r(check_name, ok) select '2 a Master can give it too, next to the other new permissions', (select permissions ->> 'manage_transfers' = 'true' and permissions ->> 'view_all_users' = 'true' and permissions ->> 'pull_back_coins' = 'true' from public.staff_roles where user_id = '00000000-0000-0000-0000-000000000011');
set role authenticated;

select public.t_who('00000000-0000-0000-0000-000000000002');
select public.set_staff_permissions('00000000-0000-0000-0000-000000000031', '{"manage_transfers": true}'::jsonb);
select public.set_staff_permissions('00000000-0000-0000-0000-000000000031', '{"manage_transfers": false}'::jsonb);
reset role;
insert into r(check_name, ok) select '3 and switches it off again', (select permissions ->> 'manage_transfers' = 'false' from public.staff_roles where user_id = '00000000-0000-0000-0000-000000000031');
set role authenticated;

select public.t_who('00000000-0000-0000-0000-000000000011');   -- a Global Admin tries to give it
do $$ begin
  begin perform public.set_staff_permissions('00000000-0000-0000-0000-000000000021', '{"manage_transfers": true}'::jsonb); insert into r(check_name, ok) values ('4 a Global Admin cannot give the permission', false);
  exception when others then insert into r(check_name, ok) values ('4 a Global Admin cannot give the permission', sqlerrm like 'Only a Super Admin or a Master%'); end;
end $$;
select public.t_who('00000000-0000-0000-0000-000000000001');
do $$ begin
  begin perform public.set_staff_permissions('00000000-0000-0000-0000-000000000011', '{"manage_transfer": true}'::jsonb); insert into r(check_name, ok) values ('5 a misspelt key is refused', false);
  exception when others then insert into r(check_name, ok) values ('5 a misspelt key is refused', sqlerrm like 'Unknown permission%'); end;
end $$;
do $$ begin
  begin perform public.set_staff_permissions('00000000-0000-0000-0000-000000000011', '{"manage_transfers": "yes"}'::jsonb); insert into r(check_name, ok) values ('6 a value that is not true / false is refused', false);
  exception when others then insert into r(check_name, ok) values ('6 a value that is not true / false is refused', sqlerrm like 'Permission manage_transfers must be true or false'); end;
end $$;
reset role;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
