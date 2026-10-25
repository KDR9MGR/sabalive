-- Exercises the free level edit (20261025110000) and the 24 hour / custom-date bans with a user-visible reason (20261025120000) on STAGING as real
-- (fake) staff and users with the real grants, then rolls back. Run through scripts/staging/verify_level_and_ban.sh. Safe: one transaction that ends in ROLLBACK.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;

create temp table who as
select
  (select s.user_id from public.staff_roles s where s.role = 'super_admin' order by s.user_id limit 1) as staff_id,
  (select p.id from public.profiles p
    where p.is_ghost = false and p.status = 'active' and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
    order by p.created_at desc limit 1) as user_id;
grant select on who to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

do $$
begin
  if (select staff_id from who) is null or (select user_id from who) is null then
    insert into res(step, ok, info) values ('setup: a Super Admin and an ordinary user exist on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  insert into ids select 'email', lower(u.email) from auth.users u where u.id = (select user_id from who);
  insert into ids select 'ladder_before', string_agg(xp_required::text, ',' order by level) from public.track_levels where track = 'wealth' and level <= 6;
end
$$;

-- ---- as the Super Admin, with the real role ----
set local role authenticated;

do $$
declare
  staff uuid := (select staff_id from who);
  n int;
  lv2 int;
  lv3 int;
  lv4 int;
  later int;
  a int;
  b int;
  c int;
begin
  if staff is null then return; end if;
  perform set_config('request.jwt.claim.sub', staff::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', staff), true);

  select xp_required into lv2 from public.track_levels where track = 'wealth' and level = 2;
  select xp_required into lv3 from public.track_levels where track = 'wealth' and level = 3;
  select xp_required into lv4 from public.track_levels where track = 'wealth' and level = 4;
  select count(*) into later from public.track_levels where track = 'wealth' and level > 2;

  -- 1 a plain edit between the neighbours shifts nothing
  begin
    n := public.admin_save_track_level_v2('wealth', 2, lv2 + 1);
    insert into res(step, ok, info) values ('1 a level edit that stays between its neighbours moves nothing', n = 0, 'moved ' || n);
  exception when others then insert into res(step, ok, info) values ('1 plain level edit', false, sqlerrm); end;

  -- 2 reaching the next level is refused without the switch
  begin
    perform public.admin_save_track_level_v2('wealth', 2, lv3 + 100);
    insert into res(step, ok, info) values ('2 raising level 2 past level 3 is refused without the switch', false, 'it was allowed');
  exception when others then
    insert into res(step, ok, info) values ('2 raising level 2 past level 3 is refused without the switch', sqlerrm like 'Level 2 needs less than%', sqlerrm);
  end;

  -- 3 with the switch every later level moves up and keeps its gap
  begin
    n := public.admin_save_track_level_v2('wealth', 2, lv3 + 100, null, true);
    select xp_required into a from public.track_levels where track = 'wealth' and level = 2;
    select xp_required into b from public.track_levels where track = 'wealth' and level = 3;
    select xp_required into c from public.track_levels where track = 'wealth' and level = 4;
    insert into res(step, ok, info) values ('3 with the switch ALL later levels move up', n = later, 'moved ' || n || ' of ' || later);
    insert into res(step, ok, info) values ('3b level 2 is what was typed', a = lv3 + 100, 'level 2 = ' || a);
    insert into res(step, ok, info) values ('3c the gaps between the later levels are kept (level 3 to 4, and 2 to 3)',
      c - b = lv4 - lv3 and b - a = lv3 - (lv2 + 1), (b - a) || ' and ' || (c - b));
    insert into res(step, ok, info) values ('3d the levels are still in strictly rising order', a < b and b < c, a || ' < ' || b || ' < ' || c);
  exception when others then insert into res(step, ok, info) values ('3 level edit with the switch', false, sqlerrm); end;
end
$$;

-- ---- bans ----
do $$
declare
  staff uuid := (select staff_id from who);
  usr uuid := (select user_id from who);
  r public.user_bans;
  mins int;
begin
  if staff is null then return; end if;
  perform set_config('request.jwt.claim.sub', staff::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', staff), true);

  begin
    select * into r from public.ban_user_v2(usr, array['account'], '24h', 'zz-smoke-test: please read the rules');
    mins := round(extract(epoch from (r.ends_at - now())) / 60);
    insert into res(step, ok, info) values ('4 a 24 hour ID ban ends in 24 hours and its reason is marked visible', mins between 1439 and 1441 and r.reason_visible, 'ends in ' || mins || ' min');
  exception when others then insert into res(step, ok, info) values ('4 24 hour ban', false, sqlerrm); end;

  begin
    select * into r from public.ban_user_v2(usr, array['live'], 'custom', 'zz-smoke-test', now() + interval '3 days');
    mins := round(extract(epoch from (r.ends_at - now())) / 60);
    insert into res(step, ok, info) values ('6 a custom date is kept (3 days)', mins between 4319 and 4321, 'ends in ' || mins || ' min');
  exception when others then insert into res(step, ok, info) values ('6 custom date ban', false, sqlerrm); end;

  begin
    perform public.ban_user_v2(usr, array['live'], 'custom', null, now() - interval '1 day');
    insert into res(step, ok, info) values ('7 a custom date in the past is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('7 a custom date in the past is refused', sqlerrm like 'The end date must be in the future', sqlerrm); end;
end
$$;

-- ---- the account is signed out until the ban ends (read as the admin role: app users cannot read auth.users) ----
reset role;
insert into res(step, ok, info)
  select '5 the account is signed out until then (banned_until follows the ban)',
         u.banned_until is not null and abs(extract(epoch from (u.banned_until - b.ends_at))) < 2, coalesce(u.banned_until::text, 'banned_until is empty')
    from auth.users u join public.user_bans b on b.user_id = u.id and b.kind = 'account' and b.lifted_at is null
   where u.id = (select user_id from who);

-- ---- before sign-in: no account, the anon role ----
set local role anon;
do $$
declare
  email text := (select val from ids where k = 'email');
  res_json jsonb;
begin
  begin
    res_json := public.check_login_access_v2('{}', email, null);
    insert into res(step, ok, info) values ('8 before sign-in, the banned account is told the end time and the reason',
      res_json ->> 'kind' = 'account' and (res_json ->> 'permanent')::boolean = false and res_json ->> 'note' = 'zz-smoke-test: please read the rules', res_json::text);
  exception when others then insert into res(step, ok, info) values ('8 pre-login check', false, sqlerrm); end;
  begin
    res_json := public.check_login_access_v2('{}', 'nobody.' || md5(random()::text) || '@example.com', null);
    insert into res(step, ok, info) values ('9 an unknown email is not banned', res_json ->> 'banned' = 'false', res_json::text);
  exception when others then insert into res(step, ok, info) values ('9 unknown email', false, sqlerrm); end;
  begin
    perform public.ban_user_v2(gen_random_uuid(), array['live'], '24h');
    insert into res(step, ok, info) values ('10 the anon role cannot ban', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('10 the anon role cannot ban', true, sqlerrm); end;
end
$$;
reset role;

-- ---- an ordinary signed-in user cannot ban or edit levels ----
set local role authenticated;
do $$
declare usr uuid := (select user_id from who);
begin
  if usr is null then return; end if;
  perform set_config('request.jwt.claim.sub', usr::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', usr), true);
  begin
    perform public.ban_user_v2(usr, array['live'], '24h');
    insert into res(step, ok, info) values ('11 an ordinary user cannot ban', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('11 an ordinary user cannot ban', true, sqlerrm); end;
  begin
    perform public.admin_save_track_level_v2('wealth', 2, 5, null, true);
    insert into res(step, ok, info) values ('12 an ordinary user cannot edit levels', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('12 an ordinary user cannot edit levels', true, sqlerrm); end;
end
$$;
reset role;

select n, step, ok, info from res order by n;

rollback;
