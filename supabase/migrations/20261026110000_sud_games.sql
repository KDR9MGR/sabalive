-- SUD games (a second game provider next to Tulasi): the database half.
--
-- SUD (console.sud.tech, "GI Cloud") hosts multiplayer party games (Ludo, Domino, Carrom, Okey 101, ...) and a few stake games. Its web SDK runs inside a page of
-- ours that the app opens in the same bottom game panel as the Tulasi games; its servers call our Edge Function `sud` (get_sstoken, update_sstoken,
-- get_user_info, report_game_info, notify and, for coin games, update_score). This file adds what those calls need.
-- EVERYTHING HERE IS NEW; no existing table or function changes. The SUD games live in their own table (sud_games), not in merchant_games: an old app build
-- reads merchant_games and would show a SUD game it cannot open, and Tulasi's "Sync Game List" would switch every row that is not Tulasi's off.
--
--   sud_games                the catalogue (SUD's game id as text: a 19-digit number the panel's JavaScript cannot hold exactly; the game's height / width from
--                            SUD's minimum-size table, since the game page has no Cocos engine to measure; whether it stakes coins). Internal ids start at
--                            1,000,000 so they never meet a Tulasi id (those are in the thousands) in the app's one merged list.
--   _sud_enabled(), _sud_coins_enabled()   the switches: app_config.feature_flags.sud_games_enabled (needs the master games_enabled too) and
--                            sud_coin_games_enabled (needs the first). Both default OFF; Release controls in the panel.
--   admin_save_sud_game(...), admin_delete_sud_game(id), admin_set_sud_games_hidden(ids, hidden)   the panel's SUD games list (Admin and above)
--   sud_launch_check(game, room)       authenticated: may this person open this game? returns what the Edge Function needs to mint the login code
--   sud_user_info(uid)                 service role: name, avatar, gender for get_sstoken / get_user_info
--   sud_apply_score(...)               service role: update_score of a coin game: consume (a bet) / gain (a win), one transaction, exactly once per order_id,
--                                      the SAME limits and ledger as the Tulasi games (game_config, game_transactions, wallet_ledger kinds game_bet / game_win)
--   sud_events + sud_log_event(...)    a short log of report_game_info and notify calls (kept 14 days)
--
-- Old app builds never call any of this. Rollback: supabase/rollbacks/20261026110000_down.sql.

-- ---------------------------------------------------------------------------
-- 1. the catalogue
-- ---------------------------------------------------------------------------
create sequence if not exists public.sud_game_id_seq start 1000000;

create table if not exists public.sud_games (
  id bigint primary key default nextval('public.sud_game_id_seq'),
  provider_game_id text not null unique check (provider_game_id ~ '^[0-9]{6,25}$'),
  name text not null check (char_length(name) between 1 and 120),
  image_url text check (image_url is null or image_url like 'https://%'),
  description text check (description is null or char_length(description) <= 500),
  aspect numeric check (aspect is null or (aspect >= 0.25 and aspect <= 4)),
  uses_coins boolean not null default false,
  status integer not null default 1 check (status in (0, 1)),
  hidden boolean not null default false,
  sort_order integer not null default 1000,
  updated_at timestamptz not null default now()
);
alter table public.sud_games enable row level security;
drop policy if exists "Signed-in users see the enabled SUD games" on public.sud_games;
create policy "Signed-in users see the enabled SUD games" on public.sud_games for select to authenticated using (status = 1 and not hidden);
drop policy if exists "Staff see every SUD game" on public.sud_games;
create policy "Staff see every SUD game" on public.sud_games for select using (public.is_admin_or_above());

-- a switch-off or a hide reaches open phones at once, like the Tulasi list
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sud_games') then
    alter publication supabase_realtime add table public.sud_games;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. the switches
-- ---------------------------------------------------------------------------
create or replace function public._sud_enabled()
returns boolean language sql stable security definer set search_path = public as $$
  select public._games_enabled()
     and coalesce((select feature_flags -> 'sud_games_enabled' = 'true'::jsonb from public.app_config where id), false);
$$;
revoke execute on function public._sud_enabled() from public, anon, authenticated;
grant execute on function public._sud_enabled() to service_role;

create or replace function public._sud_coins_enabled()
returns boolean language sql stable security definer set search_path = public as $$
  select public._sud_enabled()
     and coalesce((select feature_flags -> 'sud_coin_games_enabled' = 'true'::jsonb from public.app_config where id), false);
$$;
revoke execute on function public._sud_coins_enabled() from public, anon, authenticated;
grant execute on function public._sud_coins_enabled() to service_role;

-- ---------------------------------------------------------------------------
-- 3. the panel's SUD games list (Admin and above, like the rest of the Games page)
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_sud_game(
  p_provider_game_id text,
  p_name text,
  p_aspect numeric default null,
  p_uses_coins boolean default false,
  p_image_url text default null,
  p_description text default null,
  p_status integer default 1,
  p_sort integer default null
) returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  v_mg text := btrim(coalesce(p_provider_game_id, ''));
  v_name text := btrim(coalesce(p_name, ''));
  v_image text := nullif(btrim(coalesce(p_image_url, '')), '');
  v_id bigint;
begin
  if not public.is_admin_or_above() then
    raise exception 'Not allowed';
  end if;
  if v_mg !~ '^[0-9]{6,25}$' then
    raise exception 'The SUD game id is the long number from SUD''s game list (digits only)';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 120 then
    raise exception 'Give the game a name (up to 120 characters)';
  end if;
  if p_aspect is not null and (p_aspect < 0.25 or p_aspect > 4) then
    raise exception 'Height / width must be between 0.25 and 4';
  end if;
  if v_image is not null and v_image not like 'https://%' then
    raise exception 'The picture must be an https link';
  end if;
  if p_status is null or p_status not in (0, 1) then
    raise exception 'Status must be 0 (off) or 1 (on)';
  end if;

  insert into public.sud_games (provider_game_id, name, image_url, description, aspect, uses_coins, status, sort_order)
  values (v_mg, v_name, v_image, left(p_description, 500), p_aspect, coalesce(p_uses_coins, false), p_status, coalesce(p_sort, 1000))
  on conflict (provider_game_id) do update set
    name = excluded.name, image_url = excluded.image_url, description = excluded.description, aspect = excluded.aspect,
    uses_coins = excluded.uses_coins, status = excluded.status, sort_order = coalesce(p_sort, public.sud_games.sort_order), updated_at = now()
  returning id into v_id;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'sud_game.saved', v_mg || ' ' || left(v_name, 60), 'info');
  return v_id;
end;
$$;
revoke execute on function public.admin_save_sud_game(text, text, numeric, boolean, text, text, integer, integer) from public, anon;
grant execute on function public.admin_save_sud_game(text, text, numeric, boolean, text, text, integer, integer) to authenticated;

create or replace function public.admin_delete_sud_game(p_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin_or_above() then
    raise exception 'Not allowed';
  end if;
  delete from public.sud_games where id = p_id;
  if not found then
    raise exception 'That SUD game does not exist';
  end if;
  insert into public.audit_logs (actor_id, action, target, severity)
  values (auth.uid(), 'sud_game.deleted', p_id::text, 'warning');
end;
$$;
revoke execute on function public.admin_delete_sud_game(bigint) from public, anon;
grant execute on function public.admin_delete_sud_game(bigint) to authenticated;

create or replace function public.admin_set_sud_games_hidden(p_ids bigint[], p_hidden boolean)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_n integer;
begin
  if not public.is_admin_or_above() then
    raise exception 'Not allowed';
  end if;
  update public.sud_games
     set hidden = coalesce(p_hidden, false), updated_at = now()
   where id = any (coalesce(p_ids, '{}')) and hidden is distinct from coalesce(p_hidden, false);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.admin_set_sud_games_hidden(bigint[], boolean) from public, anon;
grant execute on function public.admin_set_sud_games_hidden(bigint[], boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. launching (the app, signed in, through the Edge Function)
-- ---------------------------------------------------------------------------
-- Everyone in the same room id plays together. From a live the room id is the live's id; from the Games tab it is the person's own (a private table).
create or replace function public.sud_launch_check(p_game_id bigint, p_room text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  g public.sud_games%rowtype;
  v_cfg public.game_config%rowtype;
  v_dob date;
  v_room text;
begin
  if v_me is null then
    raise exception 'Sign in to play';
  end if;
  if public.is_ghost(v_me) then
    raise exception 'This account cannot play games';
  end if;
  if not public._sud_enabled() then
    raise exception 'Games are not available right now';
  end if;
  select * into g from public.sud_games where id = p_game_id;
  if not found or g.hidden or g.status = 0 then
    raise exception 'This game is not available right now';
  end if;
  if g.uses_coins then
    if not public._sud_coins_enabled() then
      raise exception 'This game is not available right now';
    end if;
    select * into v_cfg from public.game_config where id;
    select date_of_birth into v_dob from public.profiles where id = v_me;
    if v_dob is null then
      raise exception 'Add your date of birth in your profile to play games';
    end if;
    if date_part('year', age(current_date, v_dob)) < v_cfg.min_age then
      raise exception 'Games are for people aged % or over', v_cfg.min_age;
    end if;
  end if;

  v_room := left(regexp_replace(coalesce(p_room, ''), '[^A-Za-z0-9_-]', '', 'g'), 64);
  if v_room = '' then
    v_room := 'solo-' || replace(v_me::text, '-', '');
  end if;
  return jsonb_build_object('ok', true, 'mg_id', g.provider_game_id, 'uid', v_me::text, 'room_id', v_room,
                            'uses_coins', g.uses_coins, 'aspect', g.aspect, 'name', g.name);
end;
$$;
revoke execute on function public.sud_launch_check(bigint, text) from public, anon;
grant execute on function public.sud_launch_check(bigint, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. what SUD asks (service role only: the Edge Function)
-- ---------------------------------------------------------------------------
create or replace function public.sud_user_info(p_uid text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_name text;
  v_avatar text;
  v_gender text;
  v_coins bigint;
begin
  begin
    v_id := p_uid::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'msg', 'unknown user');
  end;
  select coalesce(nullif(btrim(p.name), ''), 'Player'), coalesce(p.avatar_url, ''), lower(coalesce(p.gender, '')), coalesce(w.coins, 0)
    into v_name, v_avatar, v_gender, v_coins
    from public.profiles p left join public.wallets w on w.profile_id = p.id
   where p.id = v_id and not coalesce(p.is_ghost, false);
  if not found then
    return jsonb_build_object('ok', false, 'msg', 'unknown user');
  end if;
  return jsonb_build_object('ok', true, 'uid', v_id::text, 'nick_name', left(v_name, 60), 'avatar_url', v_avatar,
                            'gender', case when v_gender in ('male', 'female') then v_gender else '' end, 'coin', v_coins);
end;
$$;
revoke execute on function public.sud_user_info(text) from public, anon, authenticated;
grant execute on function public.sud_user_info(text) to service_role;

-- update_score of a coin game. p_type 1 = consume (a bet), 2 = gain (a win). Returns { ok, code, msg, coin }: code 0 success, 9000 insufficient balance,
-- 9001 duplicate order id (what SUD's documentation asks for), 1 any other refusal.
-- The rules are the Tulasi ones (game_apply_balance): exactly once per order, the wallet locked while it changes, a bet needs the coins, a bet above max_bet or
-- over the daily loss / win limit is refused, a win only after a bet on that game and not above max_payout_multiple x those bets (otherwise it is kept as
-- 'rejected' for a human). Differences: SUD sends no timestamp, so there is no 2 second rule; a table can run long, so a win may follow its bet within 6 hours;
-- and a win is still paid when games have just been switched off (a person must not lose a stake because the switch was flipped mid-round).
create or replace function public.sud_apply_score(
  p_uid text,
  p_order_id text,
  p_mg_id text,
  p_round_id text,
  p_score bigint,
  p_type integer
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_profile uuid;
  v_game public.sud_games%rowtype;
  v_uid bigint;
  v_cfg public.game_config%rowtype;
  v_tx public.game_transactions%rowtype;
  v_claimed uuid;
  v_coins bigint;
  v_bets bigint;
  v_net bigint;
  v_balance bigint;
  v_reason text;
  v_type integer;
  v_tid text := 'sud:' || coalesce(p_order_id, '');
  v_gtype text := 'sud:' || coalesce(p_mg_id, '');
begin
  if p_order_id is null or length(btrim(p_order_id)) = 0 or length(p_order_id) > 120 then
    return jsonb_build_object('ok', false, 'code', 1, 'msg', 'order_id is required');
  end if;
  begin
    v_profile := p_uid::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'code', 1, 'msg', 'unknown user');
  end;
  if not exists (select 1 from public.profiles where id = v_profile and not coalesce(is_ghost, false)) then
    return jsonb_build_object('ok', false, 'code', 1, 'msg', 'unknown user');
  end if;
  if p_type is null or p_type not in (1, 2) then
    return jsonb_build_object('ok', false, 'code', 1, 'msg', 'unsupported type');
  end if;
  v_type := case when p_type = 1 then 0 else 1 end;   -- our game_transactions use 0 = bet, 1 = win

  insert into public.game_players (profile_id) values (v_profile) on conflict (profile_id) do nothing;
  select game_uid into v_uid from public.game_players where profile_id = v_profile;

  -- claim the order first: a repeat (or a parallel twin) waits here and then gets the stored answer
  insert into public.game_transactions (transaction_id, profile_id, game_uid, game_id, game_type, type, coin, remark, ext)
  values (v_tid, v_profile, v_uid, left(p_mg_id, 40), v_gtype, v_type, coalesce(p_score, 0), left(p_round_id, 200), 'sud')
  on conflict (transaction_id) do nothing
  returning id into v_claimed;
  if v_claimed is null then
    select * into v_tx from public.game_transactions where transaction_id = v_tid;
    if v_tx.profile_id is distinct from v_profile then
      return jsonb_build_object('ok', false, 'code', 1, 'msg', 'order belongs to someone else');
    end if;
    return jsonb_build_object('ok', false, 'code', 9001, 'msg', 'duplicate order id',
                              'coin', coalesce(v_tx.balance_after, (select coins from public.wallets where profile_id = v_profile)), 'repeat', true);
  end if;

  select coins into v_coins from public.wallets where profile_id = v_profile for update;   -- one change per person at a time
  select * into v_cfg from public.game_config where id;
  select * into v_game from public.sud_games where provider_game_id = p_mg_id and uses_coins;

  if v_coins is null then
    v_reason := 'no wallet';
  elsif v_game.id is null then
    v_reason := 'not a coin game';
  elsif p_score is null or p_score < 0 or (p_type = 1 and p_score = 0) then
    v_reason := 'invalid coin amount';
  elsif p_type = 1 then
    -- a bet
    if not public._sud_coins_enabled() or v_game.hidden or v_game.status = 0 then
      v_reason := 'games are paused';
    elsif v_cfg.max_bet > 0 and p_score > v_cfg.max_bet then
      v_reason := 'bet above the limit';
    elsif v_coins < p_score then
      v_reason := 'insufficient balance';
    else
      select coalesce(sum(case when type = 0 then coin else -coin end), 0) into v_net
        from public.game_transactions
       where profile_id = v_profile and status = 'ok' and created_at > now() - interval '24 hours';
      if v_cfg.daily_loss_limit > 0 and v_net + p_score > v_cfg.daily_loss_limit then
        v_reason := 'daily limit reached';
      elsif v_cfg.daily_win_limit > 0 and -v_net >= v_cfg.daily_win_limit then
        v_reason := 'daily limit reached';
      end if;
    end if;
  else
    -- a win: only after a bet on this game, and not out of proportion to what was bet
    select coalesce(sum(coin), 0) into v_bets
      from public.game_transactions
     where profile_id = v_profile and status = 'ok' and type = 0 and game_type = v_gtype and created_at > now() - interval '6 hours';
    if p_score > 0 and v_bets = 0 then
      v_reason := 'win without a bet';
    elsif p_score > v_bets * v_cfg.max_payout_multiple then
      v_reason := 'win above the payout limit';
    end if;
  end if;

  if v_reason is not null then
    update public.game_transactions set status = 'rejected', reason = v_reason, balance_after = v_coins where id = v_claimed;
    return jsonb_build_object('ok', false, 'code', case when v_reason = 'insufficient balance' then 9000 else 1 end, 'msg', v_reason, 'coin', v_coins);
  end if;

  if p_score > 0 then
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (v_profile, case when p_type = 1 then 'game_bet' else 'game_win' end, 'coins',
            case when p_type = 1 then -p_score else p_score end, 'game_transactions', v_claimed, left(v_gtype, 60));
  end if;
  select coins into v_balance from public.wallets where profile_id = v_profile;
  update public.game_transactions set status = 'ok', reason = 'success', balance_after = v_balance where id = v_claimed;
  return jsonb_build_object('ok', true, 'code', 0, 'msg', 'success', 'coin', v_balance);
end;
$$;
revoke execute on function public.sud_apply_score(text, text, text, text, bigint, integer) from public, anon, authenticated;
grant execute on function public.sud_apply_score(text, text, text, text, bigint, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 6. a short log of what SUD reports (game start / settle, notify events)
-- ---------------------------------------------------------------------------
create table if not exists public.sud_events (
  id bigint generated always as identity primary key,
  kind text not null,
  uid text,
  mg_id text,
  room_id text,
  round_id text,
  payload jsonb,
  created_at timestamptz not null default now()
);
create index if not exists sud_events_created_idx on public.sud_events (created_at desc);
alter table public.sud_events enable row level security;
drop policy if exists "Staff read sud events" on public.sud_events;
create policy "Staff read sud events" on public.sud_events for select using (public.is_admin_or_above());

create or replace function public.sud_log_event(p_kind text, p_uid text, p_mg_id text, p_room_id text, p_round_id text, p_payload jsonb)
returns void
language sql security definer set search_path = public as $$
  insert into public.sud_events (kind, uid, mg_id, room_id, round_id, payload)
  values (left(coalesce(p_kind, 'unknown'), 60), left(p_uid, 80), left(p_mg_id, 40), left(p_room_id, 80), left(p_round_id, 120),
          case when p_payload is not null and length(p_payload::text) <= 8000 then p_payload else jsonb_build_object('truncated', true) end);
$$;
revoke execute on function public.sud_log_event(text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.sud_log_event(text, text, text, text, text, jsonb) to service_role;

do $$
begin
  perform cron.unschedule('prune-sud-events');
exception when others then null;
end $$;
select cron.schedule('prune-sud-events', '23 3 * * *', $cron$ delete from public.sud_events where created_at < now() - interval '14 days' $cron$);
