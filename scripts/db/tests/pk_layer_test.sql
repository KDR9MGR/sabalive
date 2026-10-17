-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/pk_layer_test.sql
-- Proves the PK battle layer's rules (migrations 20261017100000 + 20261017110000): who may be invited, same kind only, lengths from
-- the config, one battle per live, the random pool, the server-decided length, the forfeit sweep, and that LEGACY battles are untouched.
-- Every line prints "<what> (expect X)" and the result: compare them by eye (or grep for 'expect').

create or replace function pg_temp.raises(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'NOT raised';
exception when others then
  return 'raised: ' || sqlerrm;
end;
$$;

-- people: H1 audio host (me), H2 audio host, H3 audio host on an OLD build (not pk_ready), H4 / H5 audio hosts, V1 video host,
-- H6 blocked by H5, H7 / H8 a pair for the rate limit, L1 / L2 legacy PK hosts
insert into auth.users (id, email) values
  ('a1000001-0000-0000-0000-000000000001', 'h1@x'), ('a1000002-0000-0000-0000-000000000001', 'h2@x'),
  ('a1000003-0000-0000-0000-000000000001', 'h3@x'), ('a1000004-0000-0000-0000-000000000001', 'h4@x'),
  ('a1000005-0000-0000-0000-000000000001', 'h5@x'), ('a1000006-0000-0000-0000-000000000001', 'h6@x'),
  ('a1000007-0000-0000-0000-000000000001', 'h7@x'), ('a1000008-0000-0000-0000-000000000001', 'h8@x'),
  ('b1000001-0000-0000-0000-000000000001', 'v1@x'),
  ('c1000001-0000-0000-0000-000000000001', 'l1@x'), ('c1000002-0000-0000-0000-000000000001', 'l2@x');

insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at, pk_ready) values
  ('d1000000-0000-0000-0000-000000000001', 'a1000001-0000-0000-0000-000000000001', 's1', 'live', 'audio', now(), true),
  ('d1000000-0000-0000-0000-000000000002', 'a1000002-0000-0000-0000-000000000001', 's2', 'live', 'audio', now(), true),
  ('d1000000-0000-0000-0000-000000000003', 'a1000003-0000-0000-0000-000000000001', 's3 old build', 'live', 'audio', now(), false),
  ('d1000000-0000-0000-0000-000000000004', 'a1000004-0000-0000-0000-000000000001', 's4', 'live', 'audio', now(), true),
  ('d1000000-0000-0000-0000-000000000005', 'a1000005-0000-0000-0000-000000000001', 's5', 'live', 'audio', now(), true),
  ('d1000000-0000-0000-0000-000000000006', 'a1000006-0000-0000-0000-000000000001', 's6', 'live', 'audio', now(), true),
  ('d1000000-0000-0000-0000-000000000007', 'a1000007-0000-0000-0000-000000000001', 's7', 'live', 'audio', now(), true),
  ('d1000000-0000-0000-0000-000000000008', 'a1000008-0000-0000-0000-000000000001', 's8', 'live', 'audio', now(), true),
  ('e1000000-0000-0000-0000-000000000001', 'b1000001-0000-0000-0000-000000000001', 'sv video', 'live', 'video', now(), true),
  ('f1000000-0000-0000-0000-000000000001', 'c1000001-0000-0000-0000-000000000001', 'legacy 1', 'live', 'pk', now() - interval '10 minutes', false),
  ('f1000000-0000-0000-0000-000000000002', 'c1000002-0000-0000-0000-000000000001', 'legacy 2', 'live', 'pk', now(), false);

insert into public.follows (follower_id, followee_id) values
  ('a1000001-0000-0000-0000-000000000001', 'a1000002-0000-0000-0000-000000000001'),   -- H1 follows H2 (eligible)
  ('a1000001-0000-0000-0000-000000000001', 'a1000003-0000-0000-0000-000000000001'),   -- H3: old build
  ('a1000001-0000-0000-0000-000000000001', 'b1000001-0000-0000-0000-000000000001');   -- V1: video, other kind
insert into public.blocks (blocker_id, blocked_id) values ('a1000005-0000-0000-0000-000000000001', 'a1000006-0000-0000-0000-000000000001');

-- a LEGACY live battle (no source) whose host has been silent for 10 minutes: the sweep must leave it alone
insert into public.pk_battles (stream_a_id, stream_b_id, host_a_id, host_b_id, status, invited_at, started_at, ends_at)
values ('f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002', 'c1000001-0000-0000-0000-000000000001',
        'c1000002-0000-0000-0000-000000000001', 'live', now() - interval '9 minutes', now() - interval '9 minutes', now() + interval '1 hour');

-- 0. the new objects exist and the legacy row got the defaults
select '0 config row (expect 1)' as check, count(*) as n from public.pk_config;
select '0 pk_now is the real time (expect t)' as check, abs(extract(epoch from public.pk_now() - now())) < 5 as ok;
select '0 legacy battle: duration 300, kind / source null (expect 300, t, t)' as check, duration_seconds, kind is null as kind_null, source is null as source_null from public.pk_battles;
-- (the replay's pg_cron is a stub that records no jobs: the job is checked on the real project after the push)

-- 1. pk_set_ready: only the host of an audio / video live
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000001', false);
select '1 a stranger cannot flip my live (expect raised)' as check, pg_temp.raises($$select public.pk_set_ready('d1000000-0000-0000-0000-000000000001', false)$$) as result;
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select public.pk_set_ready('d1000000-0000-0000-0000-000000000001', false);
select '1 host turned it off (expect f)' as check, pk_ready from public.live_streams where id = 'd1000000-0000-0000-0000-000000000001';
select '1 not ready: cannot invite (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002', 300)$$) as result;
select public.pk_set_ready('d1000000-0000-0000-0000-000000000001', true);
select '1 host turned it on again (expect t)' as check, pk_ready from public.live_streams where id = 'd1000000-0000-0000-0000-000000000001';

-- 2. who H1 can invite from the Following list: H2 only (H3 is on an old build, V1 is a video live)
select '2 eligible following (expect exactly s2)' as check, title from public.pk_eligible_following('d1000000-0000-0000-0000-000000000001');

-- 3. invite rules (as H1, live in s1)
select '3 old-build host (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000003', 300)$$) as result;
select '3 other kind: audio vs video (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 300)$$) as result;
select '3 a length that is not offered (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002', 123)$$) as result;
select '3 yourself (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 300)$$) as result;
select '3 someone else''s live as mine (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000004', 'd1000000-0000-0000-0000-000000000002', 300)$$) as result;
select '3 a legacy PK-mode live (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002', 300)$$) as result;
select '3 the 40 minute length is offered, the invite is made (expect invited, audio, 2400, invite)' as check, status, kind, duration_seconds, source
  from public.pk_invite_v2('d1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002', 2400);
select '3 a second invite for the same live (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000004', 300)$$) as result;
select set_config('request.jwt.claim.sub', 'a1000004-0000-0000-0000-000000000001', false);
select '3 a third host inviting the busy s2 (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000004', 'd1000000-0000-0000-0000-000000000002', 300)$$) as result;
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select '3 busy hosts are not offered in Following (expect 0 rows)' as check, count(*) as n from public.pk_eligible_following('d1000000-0000-0000-0000-000000000001');

-- 4. accept (the existing function), then the SERVER decides the length
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000001', false);
select '4 accepted (expect accepted)' as check, status from public.respond_to_pk_invite((select id from public.pk_battles where source = 'invite'), true);
select '4 a stranger cannot begin it (expect raised)' as check, pg_temp.raises(format($$select public.pk_begin_v2(%L)$$, (select id from public.pk_battles where source = 'invite'))) as result
  from (select set_config('request.jwt.claim.sub', 'a1000004-0000-0000-0000-000000000001', false)) s;
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select '4 begun: live, ends 2400 s after it started (expect live, 2400)' as check, status, round(extract(epoch from ends_at - started_at)) as seconds
  from public.pk_begin_v2((select id from public.pk_battles where source = 'invite'));
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000001', false);
select '4 the other host calling it again changes nothing (expect live, 2400)' as check, status, round(extract(epoch from ends_at - started_at)) as seconds
  from public.pk_begin_v2((select id from public.pk_battles where source = 'invite'));

-- 5. the forfeit sweep
select public.pk_forfeit_sweep();
select '5 both hosts healthy: nothing happens (expect live)' as check, status from public.pk_battles where source = 'invite';
update public.live_streams set last_heartbeat_at = now() - interval '40 seconds' where id = 'd1000000-0000-0000-0000-000000000002';
select public.pk_forfeit_sweep();
select '5 one late heartbeat (40 s) is NOT a forfeit (expect live)' as check, status from public.pk_battles where source = 'invite';
update public.live_streams set last_heartbeat_at = now() - interval '120 seconds' where id = 'd1000000-0000-0000-0000-000000000002';
select public.pk_forfeit_sweep();
select '5 host B silent for 120 s: finished, A wins by forfeit (expect finished, a, forfeit)' as check, status, winner, end_reason from public.pk_battles where source = 'invite';
select '5 the legacy battle, host silent 10 minutes, is untouched (expect live)' as check, status from public.pk_battles where source is null;
select '5 a finished battle frees both lives: busy = (expect f, f)' as check,
  public.pk_stream_busy('d1000000-0000-0000-0000-000000000001') as s1_busy, public.pk_stream_busy('d1000000-0000-0000-0000-000000000002') as s2_busy;
update public.live_streams set last_heartbeat_at = now() where id = 'd1000000-0000-0000-0000-000000000002';

-- 6. the random pool (fixed length, kinds never mix)
select set_config('request.jwt.claim.sub', 'a1000001-0000-0000-0000-000000000001', false);
select '6 first searcher waits (expect null)' as check, public.pk_random_join('d1000000-0000-0000-0000-000000000001') as result;
select '6 asking again does not match me with myself (expect null)' as check, public.pk_random_join('d1000000-0000-0000-0000-000000000001') as result;
select set_config('request.jwt.claim.sub', 'b1000001-0000-0000-0000-000000000001', false);
select '6 a VIDEO host searching does not match the audio one (expect null)' as check, public.pk_random_join('e1000000-0000-0000-0000-000000000001') as result;
select set_config('request.jwt.claim.sub', 'a1000002-0000-0000-0000-000000000001', false);
select '6 second audio searcher is matched at once (expect accepted, random, audio, 300)' as check,
  r->>'status' as status, r->>'source' as source, r->>'kind' as kind, r->>'duration_seconds' as seconds
  from (select public.pk_random_join('d1000000-0000-0000-0000-000000000002') as r) j;
select '6 the waiting host is side A, the joiner side B (expect t, t)' as check,
  host_a_id = 'a1000001-0000-0000-0000-000000000001' as a_is_h1, host_b_id = 'a1000002-0000-0000-0000-000000000001' as b_is_h2
  from public.pk_battles where source = 'random';
select '6 both left the pool; the video host still waits (expect 1)' as check, count(*) as n from public.pk_match_queue;
select '6 a host already in a battle cannot search (expect raised)' as check, pg_temp.raises($$select public.pk_random_join('d1000000-0000-0000-0000-000000000002')$$) as result;
select set_config('request.jwt.claim.sub', 'b1000001-0000-0000-0000-000000000001', false);
select public.pk_random_leave('e1000000-0000-0000-0000-000000000001');
select '6 leaving the pool (expect 0)' as check, count(*) as n from public.pk_match_queue;
-- a stale entry is dropped and never matched
select set_config('request.jwt.claim.sub', 'a1000004-0000-0000-0000-000000000001', false);
select '6 H4 waits (expect null)' as check, public.pk_random_join('d1000000-0000-0000-0000-000000000004') as result;
update public.pk_match_queue set seen_at = now() - interval '5 minutes';
select set_config('request.jwt.claim.sub', 'a1000005-0000-0000-0000-000000000001', false);
select '6 H5 searches: H4''s stale entry was dropped, so no match (expect null)' as check, public.pk_random_join('d1000000-0000-0000-0000-000000000005') as result;
select '6 pool now only holds H5 (expect 1, s5)' as check, count(*) as n, min((select title from public.live_streams where id = stream_id)) as who from public.pk_match_queue;
-- block: H6 was blocked by H5, so they never pair
select set_config('request.jwt.claim.sub', 'a1000006-0000-0000-0000-000000000001', false);
select '6 H6 (blocked by H5) searches: no match (expect null)' as check, public.pk_random_join('d1000000-0000-0000-0000-000000000006') as result;
select '6 and cannot be invited by H5 either (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000006', 'd1000000-0000-0000-0000-000000000005', 300)$$) as result;
select public.pk_random_leave('d1000000-0000-0000-0000-000000000006');
select set_config('request.jwt.claim.sub', 'a1000005-0000-0000-0000-000000000001', false);
select public.pk_random_leave('d1000000-0000-0000-0000-000000000005');

-- 7. rate limit
update public.pk_config set invites_per_minute = 1;
select set_config('request.jwt.claim.sub', 'a1000007-0000-0000-0000-000000000001', false);
select '7 first invite is fine (expect invited)' as check, status from public.pk_invite_v2('d1000000-0000-0000-0000-000000000007', 'd1000000-0000-0000-0000-000000000008', 300);
select public.cancel_pk_battle((select id from public.pk_battles where host_a_id = 'a1000007-0000-0000-0000-000000000001'));
select '7 a second one within the minute (expect raised)' as check, pg_temp.raises($$select public.pk_invite_v2('d1000000-0000-0000-0000-000000000007', 'd1000000-0000-0000-0000-000000000008', 300)$$) as result;
update public.pk_config set invites_per_minute = 6;

-- 8. the legacy functions still work as before on a legacy pair
select set_config('request.jwt.claim.sub', 'c1000001-0000-0000-0000-000000000001', false);
select '8 legacy invite on busy legacy lives is still refused (expect raised)' as check, pg_temp.raises($$select public.invite_pk_opponent('f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002')$$) as result;
select '8 no function is callable by anon (expect 0)' as check, count(*) as n
  from information_schema.routine_privileges
  where routine_schema = 'public' and grantee = 'anon' and routine_name in ('pk_set_ready','pk_invite_v2','pk_eligible_following','pk_random_join','pk_random_leave','pk_begin_v2','pk_forfeit_sweep','pk_stream_busy','pk_hosts_blocked','pk_now');
