-- Exercises Fans (20261021180000) and staff profile tags (20261021190000) on STAGING as real (fake) users with the real grants, then rolls back.
-- Run through scripts/staging/verify_profile_patch.sh. Safe: one transaction that ends in ROLLBACK.
--
-- It checks: two ordinary users following each other become fans of each other and an unfollow takes the pair apart (the old follower counts still move);
-- the Fans list; a Master can make tags of all three looks and give them; an ordinary user cannot; what an app user can read (active tags, tags of a profile)
-- and cannot (inactive tags, any write); anonymous callers get nothing.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;

create temp table who as
with normal as (
  select p.id, row_number() over (order by p.created_at) as rn
    from public.profiles p
   where p.is_ghost = false and p.status = 'active'
     and not exists (select 1 from public.staff_roles s where s.user_id = p.id)
)
select
  (select a.id from normal a join normal b on b.rn > a.rn
    where not exists (select 1 from public.follows f where (f.follower_id = a.id and f.followee_id = b.id) or (f.follower_id = b.id and f.followee_id = a.id))
    order by a.rn, b.rn limit 1) as a_id,
  (select b.id from normal a join normal b on b.rn > a.rn
    where not exists (select 1 from public.follows f where (f.follower_id = a.id and f.followee_id = b.id) or (f.follower_id = b.id and f.followee_id = a.id))
    order by a.rn, b.rn limit 1) as b_id,
  (select id from normal order by rn desc limit 1) as c_id,
  (select s.user_id from public.staff_roles s where s.role = 'admin' order by s.created_at limit 1) as master_id;
grant select on who to public;

create temp table ids (k text primary key, v text);
grant all on ids to public;

insert into res(step, ok, info)
  select 'setup: two users with no follows between them, a third user and a Master exist on staging',
         a_id is not null and b_id is not null and c_id is not null and master_id is not null and a_id <> c_id and b_id <> c_id,
         format('a=%s b=%s c=%s master=%s', a_id is not null, b_id is not null, c_id is not null, master_id is not null)
    from who;

-- remember the counts before
insert into ids select 'a_fans', fans_count::text from public.profiles where id = (select a_id from who);
insert into ids select 'b_fans', fans_count::text from public.profiles where id = (select b_id from who);
insert into ids select 'a_followers', followers_count::text from public.profiles where id = (select a_id from who);
insert into ids select 'b_following', following_count::text from public.profiles where id = (select b_id from who);

set local role authenticated;

do $$
declare
  a uuid := (select a_id from who);
  b uuid := (select b_id from who);
  a0 int := (select v::int from ids where k = 'a_fans');
  b0 int := (select v::int from ids where k = 'b_fans');
  n int;
begin
  if a is null or b is null then return; end if;

  -- 1. A follows B (one way): no fans yet
  perform set_config('request.jwt.claim.sub', a::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', a), true);
  begin
    insert into public.follows (follower_id, followee_id) values (a, b);
    insert into res(step, ok, info)
      select '1 a one-way follow makes no fans', pa.fans_count = a0 and pb.fans_count = b0, format('a %s->%s, b %s->%s', a0, pa.fans_count, b0, pb.fans_count)
        from public.profiles pa, public.profiles pb where pa.id = a and pb.id = b;
  exception when others then
    insert into res(step, ok, info) values ('1 a user follows another', false, sqlerrm);
    return;
  end;

  -- 2. B follows back: both are fans
  perform set_config('request.jwt.claim.sub', b::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', b), true);
  begin
    insert into public.follows (follower_id, followee_id) values (b, a);
    insert into res(step, ok, info)
      select '2 following back makes a pair of fans on both sides', pa.fans_count = a0 + 1 and pb.fans_count = b0 + 1, format('a %s->%s, b %s->%s', a0, pa.fans_count, b0, pb.fans_count)
        from public.profiles pa, public.profiles pb where pa.id = a and pb.id = b;
  exception when others then
    insert into res(step, ok, info) values ('2 following back', false, sqlerrm);
    return;
  end;

  -- 3. the old follower / following counts moved by one as before
  insert into res(step, ok, info)
    select '3 the old follower and following counts moved too',
           pa.followers_count = (select v::int from ids where k = 'a_followers') + 1 and pb.following_count = (select v::int from ids where k = 'b_following') + 1,
           format('a followers %s, b following %s', pa.followers_count, pb.following_count)
      from public.profiles pa, public.profiles pb where pa.id = a and pb.id = b;

  -- 4. the Fans list (as A) contains B and B's list contains A
  select count(*) into n from public.get_fans(a) f where f.id = b;
  insert into res(step, ok, info) values ('4 the Fans list of A shows B', n = 1, 'rows: ' || n);
  perform set_config('request.jwt.claim.sub', a::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', a), true);
  select count(*) into n from public.get_fans(b) f where f.id = a;
  insert into res(step, ok, info) values ('4 the Fans list of B shows A', n = 1, 'rows: ' || n);

  -- 5. A unfollows B: the pair is gone
  delete from public.follows where follower_id = a and followee_id = b;
  insert into res(step, ok, info)
    select '5 an unfollow takes the pair apart', pa.fans_count = a0 and pb.fans_count = b0, format('a %s, b %s', pa.fans_count, pb.fans_count)
      from public.profiles pa, public.profiles pb where pa.id = a and pb.id = b;
  select count(*) into n from public.get_fans(a) f where f.id = b;
  insert into res(step, ok, info) values ('5 ...and the Fans list no longer shows B', n = 0, 'rows: ' || n);

  -- 6. nobody can follow as somebody else
  begin
    insert into public.follows (follower_id, followee_id) values (b, a);
    insert into res(step, ok, info) values ('6 following as somebody else is refused', false, 'it was allowed');
  exception when others then
    insert into res(step, ok, info) values ('6 following as somebody else is refused', true, null);
  end;
end
$$;
reset role;

-- ---------------------------------------------------------------- tags
set local role authenticated;

do $$
declare
  m uuid := (select master_id from who);
  a uuid := (select a_id from who);
  c uuid := (select c_id from who);
  pill uuid; pic uuid; plate uuid;
  n int;
  r record;
begin
  if m is null or a is null or c is null then return; end if;
  perform set_config('request.jwt.claim.sub', m::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', m), true);

  begin
    select id into pill from public.admin_save_profile_tag(null, 'zz-Official', '#7C3AED', '✔️', 'active', 1);
    select id into pic from public.admin_save_profile_tag(null, 'zz-Viscount', '#112233', null, 'active', 2, 'picture',
      'https://abcdefgh.supabase.co/storage/v1/object/public/gift-assets/tags/zz-viscount.png', null);
    select id into plate from public.admin_save_profile_tag(null, 'zz-Sahi BDM', '#118833', null, 'active', 3, 'plate',
      'https://abcdefgh.supabase.co/storage/v1/object/public/gift-assets/tags/zz-green.webp', '#FFFFFF');
    insert into res(step, ok, info) values ('7 a Master makes a pill, a picture and a plate tag', pill is not null and pic is not null and plate is not null, null);
  exception when others then
    insert into res(step, ok, info) values ('7 a Master makes tags of all three looks', false, sqlerrm);
    return;
  end;

  begin
    perform public.admin_save_profile_tag(null, 'zz-Bad', '#112233', null, 'active', 4, 'picture', null, null);
    insert into res(step, ok, info) values ('8 a picture tag without a picture is refused', false, 'it was allowed');
  exception when others then
    insert into res(step, ok, info) values ('8 a picture tag without a picture is refused', sqlerrm like 'Upload a picture%', sqlerrm);
  end;
  begin
    perform public.admin_save_profile_tag(null, 'zz-Evil', '#112233', null, 'active', 4, 'picture', 'https://evil.example.com/x.png', null);
    insert into res(step, ok, info) values ('8 a picture from another host is refused', false, 'it was allowed');
  exception when others then
    insert into res(step, ok, info) values ('8 a picture from another host is refused', sqlerrm like 'The picture must be a file uploaded%', sqlerrm);
  end;

  n := public.admin_set_user_tags(a, array[pill, pic, plate]);
  insert into res(step, ok, info) values ('9 the Master gives user A three tags', n = 3, 'tags: ' || n);

  -- a Master cannot give an inactive tag to someone new, but can retire one
  perform public.admin_save_profile_tag(pill, 'zz-Official', '#7C3AED', '✔️', 'inactive', 1);

  -- as an ordinary user C
  perform set_config('request.jwt.claim.sub', c::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', c), true);
  begin
    perform public.admin_save_profile_tag(null, 'zz-Nope', '#112233', null, 'active', 1);
    insert into res(step, ok, info) values ('10 an ordinary user cannot make a tag', false, 'it was allowed');
  exception when others then
    insert into res(step, ok, info) values ('10 an ordinary user cannot make a tag', sqlerrm like 'Only a Master%', sqlerrm);
  end;
  begin
    perform public.admin_set_user_tags(c, array[pic]);
    insert into res(step, ok, info) values ('10 ...or give one', false, 'it was allowed');
  exception when others then
    insert into res(step, ok, info) values ('10 ...or give one', sqlerrm like 'Only a Master%', sqlerrm);
  end;
  begin
    insert into public.profile_tags (name) values ('zz-direct');
    insert into res(step, ok, info) values ('10 ...or write the table directly', false, 'it was allowed');
  exception when others then
    insert into res(step, ok, info) values ('10 ...or write the table directly', sqlerrm like '%permission denied%', sqlerrm);
  end;

  -- what the app reads: A's tags, active ones only
  select count(*) into n from public.profile_tag_assignments pa join public.profile_tags t on t.id = pa.tag_id where pa.profile_id = a and t.name like 'zz-%';
  insert into res(step, ok, info) values ('11 an app user sees user A''s tags, the inactive one hidden (picture + plate)', n = 2, 'visible: ' || n);
  select count(*) into n from public.profile_tags where name like 'zz-%';
  insert into res(step, ok, info) values ('11 ...and only the active tags in the list', n = 2, 'visible: ' || n);
  select t.look, t.image_url is not null as has_image into r from public.profile_tags t where t.id = plate;
  insert into res(step, ok, info) values ('11 the plate keeps its look and picture', r.look = 'plate' and r.has_image, null);

  -- the Master still sees the inactive one
  perform set_config('request.jwt.claim.sub', m::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', m), true);
  select count(*) into n from public.profile_tags where name like 'zz-%';
  insert into res(step, ok, info) values ('12 a tag manager still sees the inactive tag', n = 3, 'visible: ' || n);

  -- deleting a tag takes it off everyone and reports how many
  n := public.admin_delete_profile_tag(pic);
  insert into res(step, ok, info) values ('13 deleting a tag reports its users and removes it', n = 1 and not exists (select 1 from public.profile_tags where id = pic), 'users: ' || n);
end
$$;
reset role;

insert into res(step, ok, info)
  select '14 anonymous callers have no access to the tag tables or functions',
         not has_table_privilege('anon', 'public.profile_tags', 'select') and not has_table_privilege('anon', 'public.profile_tag_assignments', 'select')
         and not has_function_privilege('anon', 'public.admin_set_user_tags(uuid,uuid[])', 'execute')
         and not has_function_privilege('anon', 'public.get_fans(uuid,integer)', 'execute'), null;

select n, step, ok, info from res order by n;

rollback;
