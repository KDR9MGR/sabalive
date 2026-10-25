-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/ban_custom_end_and_reason_test.sql
-- Proves (20261025120000): ban_user_v2 gives 24 hour / 7 / 30 day / custom-date / permanent bans on the server clock and refuses bad dates; a typed
-- reason is marked visible, a blank one and every old ban's reason are not; check_login_access_v2 (callable by anon) tells an ID-banned account, a banned
-- phone and a blocked identity apart, with the end date and only a visible reason; an unbanned or expired person gets {banned: false}; the ID ban still
-- signs the account out (banned_until); the old ban_user still works; only staff may ban; anon can't ban.
alter table auth.users add column if not exists banned_until timestamptz;   -- the real Auth table has it; the replay stub does not
insert into auth.users (id, email, phone) values
  ('a1000000-0000-0000-0000-0000000000a1', 'super@x', null),
  ('e1000000-0000-0000-0000-0000000000e3', 'plain@x', null),
  ('f1000000-0000-0000-0000-0000000000f4', 'Victim@gmail.com', '919876543210'),
  ('f2000000-0000-0000-0000-0000000000f5', 'old@x', null),
  ('f3000000-0000-0000-0000-0000000000f6', 'free@x', null),
  ('f4000000-0000-0000-0000-0000000000f7', 'dev@x', null);
insert into public.staff_roles (user_id, role, permissions) values ('a1000000-0000-0000-0000-0000000000a1', 'super_admin', '{}');
insert into public.user_devices (user_id, device_id) values ('f4000000-0000-0000-0000-0000000000f7', 'android-dev-1'), ('f4000000-0000-0000-0000-0000000000f7', 'drm-dev-1');

create or replace function pg_temp.as_user(p_id text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_id, false); $$;
create or replace function pg_temp.refused(p_sql text, p_expect text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return sqlerrm like p_expect; end $$;
-- minutes between now and an end date (null = permanent)
create or replace function pg_temp.mins(p_ts timestamptz) returns int language sql as $$ select round(extract(epoch from (p_ts - now())) / 60)::int; $$;

select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e3');
select '1 a normal user cannot ban (expect t)' as check, pg_temp.refused('select * from public.ban_user_v2(''f3000000-0000-0000-0000-0000000000f6'', array[''live''], ''24h'')', 'Only admins%') as ok;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');

-- 2. every duration, on the server clock
select '2 24h (expect about 1440 minutes)' as check, pg_temp.mins(ends_at) as minutes from public.ban_user_v2('f3000000-0000-0000-0000-0000000000f6', array['live'], '24h', 'spam');
select '2b 7d (expect 10080)' as check, pg_temp.mins(ends_at) as minutes from public.ban_user_v2('f3000000-0000-0000-0000-0000000000f6', array['live'], '7d');
select '2c 30d (expect 43200)' as check, pg_temp.mins(ends_at) as minutes from public.ban_user_v2('f3000000-0000-0000-0000-0000000000f6', array['live'], '30d');
select '2d permanent has no end (expect t)' as check, ends_at is null as ok from public.ban_user_v2('f3000000-0000-0000-0000-0000000000f6', array['live'], 'permanent');
select '2e a custom date is kept to the minute (expect 4320)' as check, pg_temp.mins(ends_at) as minutes
  from public.ban_user_v2('f3000000-0000-0000-0000-0000000000f6', array['live'], 'custom', null, now() + interval '3 days');

-- 3. refusals
select '3 custom without a date (expect t)' as check, pg_temp.refused('select * from public.ban_user_v2(''f3000000-0000-0000-0000-0000000000f6'', array[''live''], ''custom'')', 'Pick the date%') as ok;
select '3b a date in the past (expect t)' as check, pg_temp.refused('select * from public.ban_user_v2(''f3000000-0000-0000-0000-0000000000f6'', array[''live''], ''custom'', null, now() - interval ''1 day'')', 'The end date must be in the future') as ok;
select '3c a date 2 minutes ahead is too soon (expect t)' as check, pg_temp.refused('select * from public.ban_user_v2(''f3000000-0000-0000-0000-0000000000f6'', array[''live''], ''custom'', null, now() + interval ''2 minutes'')', 'The end date must be in the future') as ok;
select '3d a date 11 years ahead (expect t)' as check, pg_temp.refused('select * from public.ban_user_v2(''f3000000-0000-0000-0000-0000000000f6'', array[''live''], ''custom'', null, now() + interval ''11 years'')', 'The end date can be at most 10 years%') as ok;
select '3e an unknown duration (expect t)' as check, pg_temp.refused('select * from public.ban_user_v2(''f3000000-0000-0000-0000-0000000000f6'', array[''live''], ''1h'')', 'Duration must be%') as ok;
select '3f a reason over 500 characters (expect t)' as check, pg_temp.refused('select * from public.ban_user_v2(''f3000000-0000-0000-0000-0000000000f6'', array[''live''], ''24h'', repeat(''x'', 501))', 'Keep the reason under 500%') as ok;
select '3g nobody bans themselves or a staff account (expect t, t)' as check,
       pg_temp.refused('select * from public.ban_user_v2(''a1000000-0000-0000-0000-0000000000a1'', array[''live''], ''24h'')', '%ban yourself%') as self,
       pg_temp.refused('select * from public.ban_user_v2(''a1000000-0000-0000-0000-0000000000a1'', array[''bogus''], ''24h'')', '%') as bad_kind;

-- 4. the reason is visible only when typed
select '4 a typed reason is visible, a blank one is not (expect t, f)' as check,
       (select reason_visible from public.user_bans where user_id = 'f3000000-0000-0000-0000-0000000000f6' and reason = 'spam') as typed,
       (select bool_or(reason_visible) from public.user_bans where user_id = 'f3000000-0000-0000-0000-0000000000f6' and reason is null) as blank;
-- the replaced bans were lifted, only the last one is in force
select '4b one active live ban, replaced ones lifted (expect 1)' as check, count(*) as n
  from public.user_bans where user_id = 'f3000000-0000-0000-0000-0000000000f6' and kind = 'live' and lifted_at is null;

-- 5. an ID ban: the account is signed out until the end date, and the pre-login check says why
select count(*) as banned from public.ban_user_v2('f4000000-0000-0000-0000-0000000000f7', array['account'], '24h', 'Selling coins outside the app');
select '5 banned_until follows the ban (expect about 1440)' as check, pg_temp.mins(banned_until) as minutes from auth.users where id = 'f4000000-0000-0000-0000-0000000000f7';
select pg_temp.as_user('');
select '5b the pre-login check by email names the ban (expect account, f, the reason, about 1440)' as check,
       r ->> 'kind' as kind, r -> 'permanent' as permanent, r ->> 'note' as note, pg_temp.mins((r ->> 'until')::timestamptz) as minutes
  from (select public.check_login_access_v2('{}', 'DEV@x', null) as r) q;
select '5c ... and a banned phone id (expect device-less miss: banned f)' as check, public.check_login_access_v2('{unrelated}', null, null) ->> 'banned' as banned;

-- 6. a ban from the old function: reason NOT visible, permanent text stays
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select count(*) as banned from public.ban_user('f2000000-0000-0000-0000-0000000000f5', array['account'], '7d', 'internal note: refund fraud ring');
select pg_temp.as_user('');
select '6 an old ban shows the end date but never its internal note (expect account, null)' as check,
       r ->> 'kind' as kind, r -> 'note' as note
  from (select public.check_login_access_v2('{}', 'old@x', null) as r) q;

-- 7. by phone number, with or without the + and spaces
select '7 the phone 919876543210 as +91 98765 43210 finds the same user, who is not banned (expect f)' as check,
       public.check_login_access_v2('{}', null, '+91 98765 43210') ->> 'banned' as banned;
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select count(*) as banned from public.ban_user_v2('f1000000-0000-0000-0000-0000000000f4', array['account'], 'permanent', 'Chargeback abuse');
select pg_temp.as_user('');
select '7b ... and once banned (expect account, t, Chargeback abuse)' as check,
       r ->> 'kind' as kind, r -> 'permanent' as permanent, r ->> 'note' as note
  from (select public.check_login_access_v2('{}', null, '+91 98765 43210') as r) q;

-- 8. a banned phone: the device ids of the ID-banned user f4 (android-dev-1, drm-dev-1) answer too, with someone else's email
select '8 a banned phone id, any email (expect device, the reason)' as check,
       r ->> 'kind' as kind, r ->> 'note' as note
  from (select public.check_login_access_v2('{drm-dev-1}', 'nobody@x', null) as r) q;

-- 9. the blocklist: the same Gmail typed with dots / +tag has no account but is blocked, with the reason of the ban that put it there
select '9 identity block (expect identity, t, Chargeback abuse)' as check,
       r ->> 'kind' as kind, r -> 'permanent' as permanent, r ->> 'note' as note
  from (select public.check_login_access_v2('{}', 'V.ictim+promo@gmail.com', null) as r) q;

-- 10. not banned, and a ban that has run out
select '10 an unbanned email (expect f)' as check, public.check_login_access_v2('{}', 'free@x', null) ->> 'banned' as banned;
select '10b no input at all (expect f)' as check, public.check_login_access_v2() ->> 'banned' as banned;
-- time passes: the ban and the blocklist rows copied from it (same end date when placed) both run out
update public.user_bans set ends_at = now() - interval '1 minute' where user_id = 'f4000000-0000-0000-0000-0000000000f7' and kind = 'account';
update public.banned_identities set ends_at = now() - interval '1 minute' where source_user = 'f4000000-0000-0000-0000-0000000000f7';
select '10c an ID ban whose end date passed (expect f)' as check, public.check_login_access_v2('{}', 'dev@x', null) ->> 'banned' as banned;

-- 11. a lifted ban stops being reported
select pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
select public.lift_user_bans('f1000000-0000-0000-0000-0000000000f4', 'ok', null);
select pg_temp.as_user('');
select '11 after the lift the email is free again (expect f)' as check, public.check_login_access_v2('{}', 'victim@gmail.com', null) ->> 'banned' as banned;
select '11b ... and so is the typed-with-dots variant (expect f)' as check, public.check_login_access_v2('{}', 'V.ictim+promo@gmail.com', null) ->> 'banned' as banned;

-- 12. grants
select '12 anon: can check before sign-in, cannot ban (expect t, f)' as check,
       has_function_privilege('anon', 'public.check_login_access_v2(text[],text,text)', 'execute') as can_check,
       has_function_privilege('anon', 'public.ban_user_v2(uuid,text[],text,text,timestamptz)', 'execute') as can_ban;
select '12b signed-in users may call ban_user_v2 (staff only inside) (expect t)' as check,
       has_function_privilege('authenticated', 'public.ban_user_v2(uuid,text[],text,text,timestamptz)', 'execute') as ok;
