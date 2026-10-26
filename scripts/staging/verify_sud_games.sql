-- Exercises the SUD games database side (20261026110000) on STAGING with the real roles and grants, then rolls back. Run through scripts/staging/verify_sud_games.sh.
-- Uses staging's fake accounts (superadmin, user1, user2) and its own test games; changes the release switches and the game limits INSIDE the transaction only.
begin;

create temp table res (n serial, step text, ok boolean, info text);
grant all on res to public;
grant all on res_n_seq to public;
create temp table ids (k text primary key, val text);
grant all on ids to public;

do $$
declare
  staff uuid := (select user_id from public.staff_roles where role = 'super_admin' order by user_id limit 1);
  u1 uuid := (select id from auth.users where email = 'user1@staging.sabalive.test');
  u2 uuid := (select id from auth.users where email = 'user2@staging.sabalive.test');
begin
  if staff is null or u1 is null or u2 is null then
    insert into res(step, ok, info) values ('setup: the fake accounts exist on staging', false, 'run scripts/staging/bootstrap.sh');
    return;
  end if;
  update public.profiles set date_of_birth = '1990-01-01' where id = u1;                          -- an adult
  update public.profiles set date_of_birth = (current_date - interval '15 years')::date where id = u2; -- too young for a coin game
  insert into ids values ('staff', staff::text), ('u1', u1::text), ('u2', u2::text);
  -- the release switches can only be changed by the Super Admin
  perform set_config('request.jwt.claim.sub', staff::text, true);
  update public.app_config set feature_flags = (coalesce(feature_flags, '{}'::jsonb) - 'sud_games_enabled' - 'sud_coin_games_enabled') || '{"games_enabled": true}'::jsonb where id;
  insert into res(step, ok, info) values ('1 the SUD switches are off by default, even with Games on',
    public._sud_enabled() = false and public._sud_coins_enabled() = false, public._sud_enabled()::text || ' / ' || public._sud_coins_enabled()::text);
  update public.app_config set feature_flags = feature_flags || '{"sud_games_enabled": true}'::jsonb where id;
  insert into res(step, ok, info) values ('1b SUD games on = party games open, coin games still closed',
    public._sud_enabled() = true and public._sud_coins_enabled() = false, null);
  update public.game_config set max_bet = 1000, daily_loss_limit = 0, daily_win_limit = 0, max_payout_multiple = 5 where id;
end
$$;

-- panel actions as the Super Admin and as a plain user
set local role authenticated;
do $$
declare
  staff uuid := (select val::uuid from ids where k = 'staff');
  u1 uuid := (select val::uuid from ids where k = 'u1');
  v_ludo bigint; v_teen bigint; n int;
begin
  if staff is null then return; end if;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u1), true);
  begin
    perform public.admin_save_sud_game('9000000000000000001', 'ZZ Ludo');
    insert into res(step, ok, info) values ('2 an ordinary user cannot add a game', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('2 an ordinary user cannot add a game', sqlerrm like '%Not allowed%', sqlerrm); end;

  perform set_config('request.jwt.claim.sub', staff::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', staff), true);
  v_ludo := public.admin_save_sud_game('9000000000000000001', 'ZZ Ludo', 1.0, false, null, 'party', 1, 10);
  v_teen := public.admin_save_sud_game('9000000000000000002', 'ZZ TeenPatti', 1.0, true, null, null, 1, 20);
  insert into ids values ('ludo', v_ludo::text), ('teen', v_teen::text);
  insert into res(step, ok, info) values ('3 the Super Admin adds a party game and a coin game with small internal ids', v_ludo >= 1000000 and v_teen >= 1000000, v_ludo::text || ' / ' || v_teen::text);
  perform public.admin_save_sud_game('9000000000000000001', 'ZZ Ludo Plus', 1.0, false, null, 'party', 1, 10);
  select count(*) into n from public.sud_games where provider_game_id = '9000000000000000001';
  insert into res(step, ok, info) values ('3b saving the same SUD game id again updates the row', n = 1 and (select name from public.sud_games where id = v_ludo) = 'ZZ Ludo Plus', null);
  begin
    perform public.admin_save_sud_game('abc', 'X');
    insert into res(step, ok, info) values ('3c a bad game id is refused', false, 'it was allowed');
  exception when others then insert into res(step, ok, info) values ('3c a bad game id is refused', sqlerrm like '%digits only%', sqlerrm); end;
end
$$;

-- what a player sees and may open
do $$
declare
  u1 uuid := (select val::uuid from ids where k = 'u1');
  u2 uuid := (select val::uuid from ids where k = 'u2');
  staff uuid := (select val::uuid from ids where k = 'staff');
  v_ludo bigint := (select val::bigint from ids where k = 'ludo');
  v_teen bigint := (select val::bigint from ids where k = 'teen');
  n int; r jsonb;
begin
  if u1 is null or v_ludo is null then return; end if;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u1), true);
  select count(*) into n from public.sud_games where provider_game_id like '90000000000000000%';
  insert into res(step, ok, info) values ('4 a player sees the two enabled test games', n = 2, n::text);

  r := public.sud_launch_check(v_ludo, 'room 1!');
  insert into res(step, ok, info) values ('5 a party game opens; the room id is cleaned and the uid is the profile',
    (r ->> 'ok')::boolean and r ->> 'room_id' = 'room1' and r ->> 'uid' = u1::text and r ->> 'mg_id' = '9000000000000000001', r ->> 'room_id');
  r := public.sud_launch_check(v_ludo);
  insert into res(step, ok, info) values ('5b no room given = a private table', left(r ->> 'room_id', 5) = 'solo-', r ->> 'room_id');
  begin
    perform public.sud_launch_check(v_teen);
    insert into res(step, ok, info) values ('5c a coin game is closed while the coin switch is off', false, 'it opened');
  exception when others then insert into res(step, ok, info) values ('5c a coin game is closed while the coin switch is off', sqlerrm like '%not available%', sqlerrm); end;

  -- hide: the player stops seeing it at once
  perform set_config('request.jwt.claim.sub', staff::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', staff), true);
  perform public.admin_set_sud_games_hidden(array[v_ludo], true);
  perform set_config('request.jwt.claim.sub', u1::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u1), true);
  select count(*) into n from public.sud_games where provider_game_id = '9000000000000000001';
  insert into res(step, ok, info) values ('6 a hidden game disappears for players', n = 0, n::text);
  begin
    perform public.sud_launch_check(v_ludo);
    insert into res(step, ok, info) values ('6b ... and cannot be launched', false, 'it opened');
  exception when others then insert into res(step, ok, info) values ('6b ... and cannot be launched', sqlerrm like '%not available%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', staff::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', staff), true);
  perform public.admin_set_sud_games_hidden(array[v_ludo], false);
end
$$;

-- coin games: switch on (the postgres role, acting as Super Admin), then the under-age and adult cases
reset role;
do $$
declare
  staff uuid := (select val::uuid from ids where k = 'staff');
begin
  if staff is null then return; end if;
  perform set_config('request.jwt.claim.sub', staff::text, true);
  update public.app_config set feature_flags = feature_flags || '{"sud_coin_games_enabled": true}'::jsonb where id;
end
$$;
set local role authenticated;
do $$
declare
  u1 uuid := (select val::uuid from ids where k = 'u1');
  u2 uuid := (select val::uuid from ids where k = 'u2');
  v_teen bigint := (select val::bigint from ids where k = 'teen');
begin
  if u1 is null or v_teen is null then return; end if;
  perform set_config('request.jwt.claim.sub', u1::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u1), true);
  insert into res(step, ok, info) values ('7 an adult can open a coin game once the coin switch is on', (public.sud_launch_check(v_teen) ->> 'ok')::boolean, null);
  perform set_config('request.jwt.claim.sub', u2::text, true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u2), true);
  begin
    perform public.sud_launch_check(v_teen);
    insert into res(step, ok, info) values ('7b a 15 year old cannot open a coin game', false, 'it opened');
  exception when others then insert into res(step, ok, info) values ('7b a 15 year old cannot open a coin game', sqlerrm like '%18%', sqlerrm); end;
end
$$;

-- the money side: only the service role (here: the postgres role) may call it
reset role;
do $$
declare
  u1 uuid := (select val::uuid from ids where k = 'u1');
  start_coins bigint; r jsonb;
begin
  if u1 is null then return; end if;
  select coins into start_coins from public.wallets where profile_id = u1;
  r := public.sud_apply_score(u1::text, 'zz-ord-1', '9000000000000000002', 'zz-round-1', 100, 1);
  insert into res(step, ok, info) values ('8 a bet takes the coins once', (r ->> 'code')::int = 0 and (select coins from public.wallets where profile_id = u1) = start_coins - 100, r::text);
  r := public.sud_apply_score(u1::text, 'zz-ord-1', '9000000000000000002', 'zz-round-1', 100, 1);
  insert into res(step, ok, info) values ('8b the same order again is code 9001 and charges nothing', (r ->> 'code')::int = 9001 and (select coins from public.wallets where profile_id = u1) = start_coins - 100, r::text);
  r := public.sud_apply_score(u1::text, 'zz-ord-2', '9000000000000000002', 'zz-round-1', 500, 2);
  insert into res(step, ok, info) values ('8c a win pays', (r ->> 'code')::int = 0 and (select coins from public.wallets where profile_id = u1) = start_coins + 400, r::text);
  r := public.sud_apply_score(u1::text, 'zz-ord-3', '9000000000000000002', 'zz-round-1', 600, 2);
  insert into res(step, ok, info) values ('8d a win above 5 x the bet is refused', (r ->> 'code')::int <> 0 and (select coins from public.wallets where profile_id = u1) = start_coins + 400, r ->> 'msg');
  r := public.sud_apply_score(u1::text, 'zz-ord-4', '9000000000000000002', 'zz-round-2', 1001, 1);
  insert into res(step, ok, info) values ('8e a bet above the maximum is refused', (r ->> 'code')::int <> 0, r ->> 'msg');
  r := public.sud_apply_score(u1::text, 'zz-ord-5', '9000000000000000001', 'zz-round-3', 10, 1);
  insert into res(step, ok, info) values ('8f a party game never moves coins', (r ->> 'code')::int <> 0, r ->> 'msg');
  insert into res(step, ok, info)
    select '8g the ledger carries the game kinds', count(*) filter (where kind = 'game_bet' and amount = -100) = 1 and count(*) filter (where kind = 'game_win' and amount = 500) = 1, null
      from public.wallet_ledger where profile_id = u1 and note like 'sud:9000000000000000002%';
end
$$;

insert into res(step, ok, info) values ('9 the money functions are not callable by app users or anon',
  not has_function_privilege('anon', 'public.sud_apply_score(text,text,text,text,bigint,integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.sud_apply_score(text,text,text,text,bigint,integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.sud_user_info(text)', 'execute')
  and not has_function_privilege('anon', 'public.sud_launch_check(bigint,text)', 'execute')
  and has_function_privilege('authenticated', 'public.sud_launch_check(bigint,text)', 'execute'), null);

select n, step, ok, info from res order by n;

rollback;
