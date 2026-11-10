-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/view_all_users_test.sql
-- Proves (20261110110000): with "Limit each admin to their own chain" ON, a Global Admin sees only its chain; once a Super Admin (or a Master) gives it `view_all_users` it sees every profile
-- like a Master, but gets no write power from it; taking the permission away limits it again; a Global Admin cannot give the permission; a misspelt key is refused; with the switch OFF
-- nothing changes for anybody.
insert into auth.users (id, email, raw_user_meta_data)
select v.id::uuid, v.email, jsonb_build_object('username', 'usr_' || split_part(v.email, '@', 1)) from (values
  ('00000000-0000-0000-0000-000000000001', 's0@x'), ('00000000-0000-0000-0000-000000000002', 'm0@x'),
  ('00000000-0000-0000-0000-000000000011', 'g1@x'), ('00000000-0000-0000-0000-000000000012', 'g2@x'),
  ('00000000-0000-0000-0000-000000000021', 'c1@x'), ('00000000-0000-0000-0000-000000000023', 'c3@x'),
  ('00000000-0000-0000-0000-000000000062', 'u2@x')) v(id, email);
update public.profiles p set name = upper(split_part(u.email, '@', 1)), username = 'user_' || split_part(u.email, '@', 1) from auth.users u where u.id = p.id;
insert into public.staff_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000000001', 'super_admin'), ('00000000-0000-0000-0000-000000000002', 'admin'),
  ('00000000-0000-0000-0000-000000000011', 'global_admin'), ('00000000-0000-0000-0000-000000000012', 'global_admin');
insert into public.staff_roles (user_id, role, global_admin_id) values
  ('00000000-0000-0000-0000-000000000021', 'country_admin', '00000000-0000-0000-0000-000000000011'),
  ('00000000-0000-0000-0000-000000000023', 'country_admin', null);

create function public.t_who(p_sub text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_sub, false) $$;
create function public.t_set_switch(p_on boolean) returns void language plpgsql security definer as $$
declare v_was text := current_setting('request.jwt.claim.sub', true);
begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
  update public.app_config set feature_flags = case when p_on then feature_flags || '{"limit_staff_to_own_chain": true}'::jsonb else feature_flags - 'limit_staff_to_own_chain' end where id;
  perform set_config('request.jwt.claim.sub', coalesce(v_was, ''), false);
end $$;
insert into public.coin_transfers (sender_id, recipient_id, coins, recipient_kind) values ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000062', 5, 'user');
create temp table r (n serial, check_name text, ok boolean);
create temp table total as select count(*)::int as n, (select count(*)::int from public.staff_roles) as staff, (select count(*)::int from public.wallets) as wallets, (select count(*)::int from public.coin_transfers) as transfers from public.profiles;
grant all on r, total to authenticated;
grant usage, select on sequence r_n_seq to authenticated;
grant execute on function public.t_who(text), public.t_set_switch(boolean) to authenticated;

select public.t_set_switch(true);
set role authenticated;

-- 1. limited without the permission
select public.t_who('00000000-0000-0000-0000-000000000011');   -- G1
insert into r(check_name, ok) select '1 with the switch ON a Global Admin without the permission sees only its chain (not an ordinary user, not a stranger Country Admin)',
  not exists (select 1 from public.profiles where id in ('00000000-0000-0000-0000-000000000062', '00000000-0000-0000-0000-000000000023'))
  and (select count(*) from public.profiles) < (select n from total);

-- 2. the Super Admin gives it
select public.t_who('00000000-0000-0000-0000-000000000001');   -- S0
select public.set_staff_permissions('00000000-0000-0000-0000-000000000011', '{"view_all_users": true}'::jsonb);
select public.t_who('00000000-0000-0000-0000-000000000011');
insert into r(check_name, ok) select '2 after the Super Admin gives view_all_users the Global Admin sees every profile, like a Master',
  (select count(*) from public.profiles) = (select n from total);
insert into r(check_name, ok) select '2b ... and every staff row, wallet and coin transfer too (a transfer between two strangers)',
  (select count(*) from public.staff_roles) = (select staff from total) and (select count(*) from public.wallets) = (select wallets from total) and (select count(*) from public.coin_transfers) = (select transfers from total);

-- 3. no write power from it
create temp table upd as select 0 as n;
grant all on upd to authenticated;
with u as (update public.profiles set bio = 'changed by G1' where id = '00000000-0000-0000-0000-000000000062' returning 1) update upd set n = (select count(*) from u);
insert into r(check_name, ok) select '3 seeing everyone gives no write power: the Global Admin still cannot change another profile', (select n from upd) = 0;

-- 4. taking it away limits it again
select public.t_who('00000000-0000-0000-0000-000000000001');
select public.set_staff_permissions('00000000-0000-0000-0000-000000000011', '{"view_all_users": false}'::jsonb);
select public.t_who('00000000-0000-0000-0000-000000000011');
insert into r(check_name, ok) select '4 with the permission switched off the Global Admin is limited again (profiles and a stranger transfer)', (select count(*) from public.profiles) < (select n from total) and (select count(*) from public.coin_transfers) < (select transfers from total);

-- 5. a Master can give it; a Global Admin cannot; a misspelt key is refused
select public.t_who('00000000-0000-0000-0000-000000000002');   -- M0
select public.set_staff_permissions('00000000-0000-0000-0000-000000000012', '{"view_all_users": true}'::jsonb);
select public.t_who('00000000-0000-0000-0000-000000000012');   -- G2
insert into r(check_name, ok) select '5 a Master can give view_all_users (G2 now sees every profile)', (select count(*) from public.profiles) = (select n from total);
select public.t_who('00000000-0000-0000-0000-000000000011');   -- G1 tries to give it to C1
do $$ begin
  begin perform public.set_staff_permissions('00000000-0000-0000-0000-000000000021', '{"view_all_users": true}'::jsonb); insert into r(check_name, ok) values ('6 a Global Admin cannot give the permission', false);
  exception when others then insert into r(check_name, ok) values ('6 a Global Admin cannot give the permission', sqlerrm like 'Only a Super Admin or a Master%'); end;
end $$;
select public.t_who('00000000-0000-0000-0000-000000000001');
do $$ begin
  begin perform public.set_staff_permissions('00000000-0000-0000-0000-000000000011', '{"view_all_user": true}'::jsonb); insert into r(check_name, ok) values ('7 a misspelt key is refused', false);
  exception when others then insert into r(check_name, ok) values ('7 a misspelt key is refused', sqlerrm like 'Unknown permission%'); end;
end $$;

-- 8. switch OFF: nothing changes for anybody
reset role;
select public.t_set_switch(false);
set role authenticated;
select public.t_who('00000000-0000-0000-0000-000000000011');
insert into r(check_name, ok) select '8 with the switch OFF everyone sees everyone as before', (select count(*) from public.profiles) = (select n from total);
reset role;

select n, check_name, ok from r order by n;
select case when count(*) filter (where not ok) = 0 then 'ALL PASSED (' || count(*) || ' checks)' else count(*) filter (where not ok) || ' CHECK(S) FAILED' end as result from r;
