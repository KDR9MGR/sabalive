-- Exercises 20261026140000 on STAGING with the real roles and grants, then rolls back: Send to All includes the sender (v3) while v2 still leaves them out, and the diamond
-- reset is the reset_diamonds permission. Run through scripts/staging/verify_quick_fixes.sh. Builds its own people, a live, a seat and a gift; ends in ROLLBACK.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

do $$
declare
  master uuid := (select user_id from public.staff_roles where role = 'admin' order by user_id limit 1);
  super uuid := (select user_id from public.staff_roles where role = 'super_admin' order by user_id limit 1);
  h uuid := gen_random_uuid(); s uuid := gen_random_uuid(); g uuid := gen_random_uuid(); v uuid := gen_random_uuid();
  live uuid := gen_random_uuid(); gift uuid := gen_random_uuid();
begin
  if master is null or super is null then
    insert into res(step, ok, info) values ('setup: a Master and a Super Admin exist on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  insert into auth.users (id, aud, role, email, raw_user_meta_data) values
    (h, 'authenticated', 'authenticated', 'zz-smoke-qfh@staging.sabalive.test', '{"name":"ZZ Host"}'),
    (s, 'authenticated', 'authenticated', 'zz-smoke-qfs@staging.sabalive.test', '{"name":"ZZ Sender"}'),
    (g, 'authenticated', 'authenticated', 'zz-smoke-qfg@staging.sabalive.test', '{"name":"ZZ Guest"}'),
    (v, 'authenticated', 'authenticated', 'zz-smoke-qfv@staging.sabalive.test', '{"name":"ZZ Viewer"}');
  insert into public.live_streams (id, host_id, title, status, mode, last_heartbeat_at) values (live, h, 'zz quick fixes', 'live', 'audio', now());
  insert into public.live_stream_seats (live_stream_id, seat_number, occupant_id, last_heartbeat_at) values (live, 1, h, now()), (live, 2, g, now()), (live, 3, s, now());
  insert into public.gifts (id, name, emoji, price_coins) values (gift, 'ZZ Rose', 'R', 10);
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note) values
    (s, 'purchase', 'coins', 1000, 'coin_purchases', 'zz funds'), (v, 'purchase', 'coins', 1000, 'coin_purchases', 'zz funds');
  insert into ids values ('master', master::text), ('super', super::text), ('h', h::text), ('s', s::text), ('g', g::text), ('v', v::text), ('live', live::text), ('gift', gift::text);
end
$$;

set local role authenticated;
do $$
declare
  s uuid := (select val::uuid from ids where k = 's');
  v uuid := (select val::uuid from ids where k = 'v');
  live uuid := (select val::uuid from ids where k = 'live');
  gift uuid := (select val::uuid from ids where k = 'gift');
  n integer;
begin
  if s is null then return; end if;
  perform set_config('request.jwt.claim.sub', s::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', s), true);
  n := public.send_gift_to_all_v3(gift, live, 2);
  insert into res(step, ok, info) values ('1 a seated sender reaches host, guest and themselves = 3 people', n = 3, n::text);
  insert into res(step, ok, info) select '1b charged 3 x 2 x 10 = 60', (select coins from public.wallets where profile_id = s) = 940, null;
  insert into res(step, ok, info) select '1c the sender got their own share as diamonds (2 x 10)', (select diamonds from public.wallets where profile_id = s) = 20, null;
  insert into res(step, ok, info)
    select '1d ONE chat line: to all, 3 receivers, the sender among them',
      count(*) = 1 and bool_and(to_all) and min(cardinality(gift_receiver_ids)) = 3 and bool_and(s = any(gift_receiver_ids)), min(body)
      from public.live_chat_messages where live_stream_id = live and kind = 'gift';
  n := public.send_gift_to_all_v2(gift, live, 1);
  insert into res(step, ok, info) values ('2 v2 (old apps) still leaves the sender out: 2 people', n = 2, n::text);

  perform set_config('request.jwt.claim.sub', v::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
  n := public.send_gift_to_all_v3(gift, live, 1);
  insert into res(step, ok, info) values ('3 a viewer who is not on a seat reaches the 3 seated people and gets nothing back', n = 3 and (select diamonds from public.wallets where profile_id = v) = 0, n::text);
end
$$;
reset role;

-- the diamond reset is the reset_diamonds permission
set local role authenticated;
do $$
declare
  master uuid := (select val::uuid from ids where k = 'master');
  super uuid := (select val::uuid from ids where k = 'super');
  p jsonb;
begin
  if master is null then return; end if;
  perform set_config('request.jwt.claim.sub', master::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', master), true);
  p := public.admin_diamond_reset_preview('2026-03');
  insert into res(step, ok, info) values ('4 a Master has the diamond reset by default', p is not null, null);

  perform set_config('request.jwt.claim.sub', super::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', super), true);
  begin
    perform public.set_staff_permissions(master, '{"reset_diamonds": false}'::jsonb);
    insert into res(step, ok, info) values ('5 the Super Admin switches it off for that Master (the key is accepted)', true, null);
  exception when others then insert into res(step, ok, info) values ('5 the Super Admin switches it off for that Master (the key is accepted)', false, sqlerrm); end;

  perform set_config('request.jwt.claim.sub', master::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', master), true);
  begin
    perform public.admin_diamond_reset_preview('2026-03');
    insert into res(step, ok, info) values ('5b ... and the Master is refused at once', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('5b ... and the Master is refused at once', sqlerrm like '%Only a Master or Super Admin%', sqlerrm); end;
  begin
    perform public.admin_reset_diamonds('2026-03', 'gift', '2026-03');
    insert into res(step, ok, info) values ('5c ... for the reset too', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('5c ... for the reset too', sqlerrm like '%Only a Master or Super Admin%', sqlerrm); end;

  perform set_config('request.jwt.claim.sub', super::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', super), true);
  p := public.admin_diamond_reset_preview('2026-03');
  insert into res(step, ok, info) values ('6 the Super Admin always has it', p is not null, null);
end
$$;
reset role;
insert into res(step, ok, info) values ('7 anon cannot call the new function',
  not has_function_privilege('anon', 'public.send_gift_to_all_v3(uuid,uuid,integer)', 'execute')
  and has_function_privilege('authenticated', 'public.send_gift_to_all_v3(uuid,uuid,integer)', 'execute'), null);

select n, step, ok, info from res order by n;

rollback;
