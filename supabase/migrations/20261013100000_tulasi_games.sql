-- Tulasi games (merchant integration): the database half.
--
-- Tulasi hosts the games; its servers call our Edge Function `tulasi` (userInformation / updateBalance /
-- updateGameList) and our app opens the game in a WebView with a per-launch token. This file adds what those calls
-- need. Everything is NEW: no existing table or function changes, except that the wallet ledger accepts two more
-- kinds ('game_bet', 'game_win') so every game coin is traceable in the same ledger the wallet already uses.
--
--   game_config        caps the server enforces (single row): max bet, daily loss / win limit, how much a round may pay
--                      compared with what was bet, token lifetime. The on/off switch is NOT here: it is
--                      app_config.feature_flags.games_enabled (Release controls in the panel), the same switch the app reads.
--   game_players       a permanent numeric id per profile (Tulasi wants a Long; profiles.display_id changes when a Lucky ID
--                      is held, so it cannot be used)
--   game_sessions      one row per launch: only the SHA-256 of the token is stored
--   game_transactions  every updateBalance call by transactionId: idempotency + audit (rejected calls are kept too)
--   start_game_session(game)           authenticated: 18+, not a ghost, games on -> a fresh token
--   game_get_user(token)               service role only: what userInformation returns
--   game_apply_balance(...)            service role only: bet (type 0) / win (type 1), one transaction, exactly once
--
-- Money rules (all in game_apply_balance): a bet needs enough coins, a request more than 2 s old or after the round's end time is
-- refused, a bet above max_bet or over the daily loss limit is refused, a win is accepted only after a bet on that game in the last
-- 15 minutes and not above max_payout_multiple x those bets (otherwise it is kept as 'rejected' for a human to look at). The wallet
-- changes through the existing ledger trigger, so wallets.coins >= 0 still protects every balance. Game coins are normal coins
-- (owner's decision); the separate kinds exist so they can be monitored.
--
-- Old app builds do not know any of this and never call it. Rollback: supabase/rollbacks/20261013100000_tulasi_games_down.sql.

-- ---------------------------------------------------------------------------
-- 1. ledger kinds (read the CURRENT constraint, add ours: it was regressed once by re-emitting a stale list)
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_new text;
begin
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conname = 'wallet_ledger_kind_check' and c.conrelid = 'public.wallet_ledger'::regclass;
  if v_def is null then
    raise exception 'wallet_ledger_kind_check not found';
  end if;
  if v_def like '%game_bet%' then
    return; -- already there
  end if;
  -- CHECK ((kind = ANY (ARRAY['purchase'::text, ..., 'grant_reversal'::text])))  ->  append our two kinds to the array
  v_new := regexp_replace(v_def, '(::text)\]\)', '\1, ''game_bet''::text, ''game_win''::text])');
  if v_new = v_def or v_new not like '%game_win%' then
    raise exception 'could not extend wallet_ledger_kind_check from: %', v_def;
  end if;
  alter table public.wallet_ledger drop constraint wallet_ledger_kind_check;
  -- NOT VALID: enforced for every new row at once, but the existing rows are not re-scanned under the lock that blocks every coin movement
  -- (the old kinds are a subset of the new list, so they are known-good). Validate later, off the critical path, with
  --   alter table public.wallet_ledger validate constraint wallet_ledger_kind_check;   (it does not block writes)
  execute 'alter table public.wallet_ledger add constraint wallet_ledger_kind_check ' || v_new || ' not valid';
end $$;

-- ---------------------------------------------------------------------------
-- 2. tables
-- ---------------------------------------------------------------------------
create table if not exists public.game_config (
  id boolean primary key default true check (id),
  max_bet bigint not null default 100000 check (max_bet >= 0),
  daily_loss_limit bigint not null default 0 check (daily_loss_limit >= 0),
  daily_win_limit bigint not null default 0 check (daily_win_limit >= 0),
  max_payout_multiple integer not null default 100 check (max_payout_multiple >= 1),
  session_hours integer not null default 4 check (session_hours between 1 and 48),
  min_age integer not null default 18 check (min_age between 13 and 99),
  updated_at timestamptz not null default now()
);
comment on column public.game_config.max_bet is 'Largest single bet in coins; 0 = no cap.';
comment on column public.game_config.daily_loss_limit is 'Net coins a person may lose in 24 hours before new bets are refused; 0 = no limit.';
comment on column public.game_config.daily_win_limit is 'Net coins a person may win in 24 hours before new bets are refused; 0 = no limit.';
comment on column public.game_config.max_payout_multiple is 'A win may not exceed this many times what the person bet on that game in the last 15 minutes.';
insert into public.game_config (id) values (true) on conflict (id) do nothing;
alter table public.game_config enable row level security;
drop policy if exists "Staff read game config" on public.game_config;
create policy "Staff read game config" on public.game_config for select using (public.is_admin_or_above());
drop policy if exists "Admins update game config" on public.game_config;
create policy "Admins update game config" on public.game_config for update
  using (public.is_admin_or_above()) with check (public.is_admin_or_above());

create table if not exists public.game_players (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  game_uid bigint generated always as identity (start with 10001) unique,
  created_at timestamptz not null default now()
);
alter table public.game_players enable row level security;
drop policy if exists "Staff read game players" on public.game_players;
create policy "Staff read game players" on public.game_players for select using (public.is_admin_or_above());

create table if not exists public.game_sessions (
  token_hash text primary key,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  game_id text,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists game_sessions_profile_idx on public.game_sessions (profile_id, created_at desc);
alter table public.game_sessions enable row level security;   -- no policy at all: only the functions below read it

create table if not exists public.game_transactions (
  id uuid primary key default gen_random_uuid(),
  transaction_id text not null unique,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  game_uid bigint not null,
  game_id text,
  game_type text,
  type integer not null,
  coin bigint not null default 0,
  round_start bigint,
  round_end bigint,
  request_ts bigint,
  remark text,
  ext text,
  status text not null default 'pending' check (status in ('pending', 'ok', 'rejected')),
  reason text,
  balance_after bigint,
  created_at timestamptz not null default now()
);
create index if not exists game_transactions_profile_idx on public.game_transactions (profile_id, created_at desc);
create index if not exists game_transactions_game_idx on public.game_transactions (game_type, created_at desc);
alter table public.game_transactions enable row level security;
drop policy if exists "Staff read game transactions" on public.game_transactions;
create policy "Staff read game transactions" on public.game_transactions for select using (public.is_admin_or_above());

-- net result per person per day, for the panel's monitoring (security_invoker: the caller's own access applies)
create or replace view public.game_player_day_totals with (security_invoker = true) as
select profile_id,
       (created_at at time zone 'UTC')::date as day,
       coalesce(sum(coin) filter (where type = 0 and status = 'ok'), 0) as bet,
       coalesce(sum(coin) filter (where type = 1 and status = 'ok'), 0) as won,
       coalesce(sum(coin) filter (where type = 1 and status = 'ok'), 0)
         - coalesce(sum(coin) filter (where type = 0 and status = 'ok'), 0) as net,
       count(*) filter (where status = 'rejected') as rejected
  from public.game_transactions
 group by 1, 2;

-- ---------------------------------------------------------------------------
-- 3. helpers
-- ---------------------------------------------------------------------------
create or replace function public._games_enabled()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select feature_flags -> 'games_enabled' = 'true'::jsonb from public.app_config where id), false);
$$;
revoke execute on function public._games_enabled() from public, anon, authenticated;
grant execute on function public._games_enabled() to service_role;

-- ---------------------------------------------------------------------------
-- 4. launching a game (the app, signed in)
-- ---------------------------------------------------------------------------
create or replace function public.start_game_session(p_game_id text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_cfg public.game_config%rowtype;
  v_dob date;
  v_uid bigint;
  v_token text;
  v_expires timestamptz;
begin
  if v_me is null then
    raise exception 'Sign in to play';
  end if;
  if public.is_ghost(v_me) then
    raise exception 'This account cannot play games';
  end if;
  if not public._games_enabled() then
    raise exception 'Games are not available right now';
  end if;
  select * into v_cfg from public.game_config where id;
  select date_of_birth into v_dob from public.profiles where id = v_me;
  if v_dob is null then
    raise exception 'Add your date of birth in your profile to play games';
  end if;
  if date_part('year', age(current_date, v_dob)) < v_cfg.min_age then
    raise exception 'Games are for people aged % or over', v_cfg.min_age;
  end if;

  insert into public.game_players (profile_id) values (v_me) on conflict (profile_id) do nothing;
  select game_uid into v_uid from public.game_players where profile_id = v_me;

  -- housekeeping: this person's expired launches, and all but their newest few
  delete from public.game_sessions where profile_id = v_me and expires_at < now();
  delete from public.game_sessions
   where profile_id = v_me
     and token_hash not in (select token_hash from public.game_sessions where profile_id = v_me order by created_at desc limit 4);

  v_token := replace(gen_random_uuid()::text, '-', '');   -- 32 hex characters from the server's secure random
  v_expires := now() + make_interval(hours => v_cfg.session_hours);
  insert into public.game_sessions (token_hash, profile_id, game_id, expires_at)
  values (encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), v_me, p_game_id, v_expires);

  return jsonb_build_object('token', v_token, 'uid', v_uid, 'expires_at', v_expires);
end;
$$;
revoke execute on function public.start_game_session(text) from public, anon;
grant execute on function public.start_game_session(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. what Tulasi asks (service role only: the Edge Function)
-- ---------------------------------------------------------------------------
create or replace function public.game_get_user(p_token text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_session public.game_sessions%rowtype;
  v_uid bigint;
  v_name text;
  v_avatar text;
  v_coins bigint;
begin
  if not public._games_enabled() then
    return jsonb_build_object('ok', false, 'msg', 'games are paused');
  end if;
  select * into v_session from public.game_sessions
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') and expires_at > now();
  if not found then
    return jsonb_build_object('ok', false, 'msg', 'invalid token');
  end if;
  select game_uid into v_uid from public.game_players where profile_id = v_session.profile_id;
  select coalesce(p.name, ''), coalesce(p.avatar_url, ''), coalesce(w.coins, 0)
    into v_name, v_avatar, v_coins
    from public.profiles p left join public.wallets w on w.profile_id = p.id
   where p.id = v_session.profile_id;
  return jsonb_build_object('ok', true, 'id', v_uid, 'nickname', v_name, 'avatar', v_avatar, 'coin', v_coins, 'gameCoin', 0);
end;
$$;
revoke execute on function public.game_get_user(text) from public, anon, authenticated;
grant execute on function public.game_get_user(text) to service_role;

create or replace function public.game_apply_balance(
  p_token text,
  p_uid bigint,
  p_transaction_id text,
  p_type integer,
  p_coin bigint,
  p_game_id text,
  p_game_type text,
  p_timestamp bigint,
  p_game_start bigint default null,
  p_game_end bigint default null,
  p_ext text default null,
  p_remark text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_now_ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_cfg public.game_config%rowtype;
  v_session public.game_sessions%rowtype;
  v_uid bigint;
  v_tx public.game_transactions%rowtype;
  v_claimed uuid;
  v_coins bigint;
  v_bets bigint;
  v_net bigint;
  v_balance bigint;
  v_reason text;
begin
  if p_transaction_id is null or length(p_transaction_id) = 0 then
    return jsonb_build_object('ok', false, 'msg', 'transactionId is required');
  end if;
  select * into v_session from public.game_sessions
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') and expires_at > now();
  if not found then
    return jsonb_build_object('ok', false, 'msg', 'invalid token');
  end if;
  select game_uid into v_uid from public.game_players where profile_id = v_session.profile_id;
  if v_uid is distinct from p_uid then
    return jsonb_build_object('ok', false, 'msg', 'uid does not match the token');
  end if;

  -- claim the transactionId first: a repeat (or a parallel twin) waits here and then gets the stored answer
  insert into public.game_transactions
    (transaction_id, profile_id, game_uid, game_id, game_type, type, coin, round_start, round_end, request_ts, remark, ext)
  values
    (p_transaction_id, v_session.profile_id, v_uid, p_game_id, p_game_type, p_type, coalesce(p_coin, 0), p_game_start, p_game_end, p_timestamp, left(p_remark, 200), left(p_ext, 200))
  on conflict (transaction_id) do nothing
  returning id into v_claimed;
  if v_claimed is null then
    select * into v_tx from public.game_transactions where transaction_id = p_transaction_id;
    if v_tx.profile_id is distinct from v_session.profile_id then
      return jsonb_build_object('ok', false, 'msg', 'transactionId belongs to someone else');
    end if;
    return jsonb_build_object('ok', v_tx.status = 'ok', 'msg', coalesce(v_tx.reason, 'success'),
                              'coin', coalesce(v_tx.balance_after, (select coins from public.wallets where profile_id = v_session.profile_id)),
                              'id', v_uid, 'repeat', true);
  end if;

  select * into v_cfg from public.game_config where id;
  -- lock the wallet for the rest of this transaction: bets for one person are applied one at a time
  select coins into v_coins from public.wallets where profile_id = v_session.profile_id for update;
  if v_coins is null then
    v_reason := 'no wallet';
  elsif not public._games_enabled() then
    v_reason := 'games are paused';
  elsif p_type not in (0, 1) then
    v_reason := 'unsupported type';
  elsif p_coin is null or p_coin < 0 or (p_type = 0 and p_coin = 0) then
    v_reason := 'invalid coin amount';
  elsif p_type = 0 then
    if p_timestamp is null or abs(v_now_ms - p_timestamp) > 2000 then
      v_reason := 'timeout';
    elsif p_game_end is null or v_now_ms >= p_game_end then
      v_reason := 'game timeout';
    elsif v_cfg.max_bet > 0 and p_coin > v_cfg.max_bet then
      v_reason := 'bet above the limit';
    elsif v_coins < p_coin then
      v_reason := 'insufficient balance';
    else
      select coalesce(sum(case when type = 0 then coin else -coin end), 0) into v_net
        from public.game_transactions
       where profile_id = v_session.profile_id and status = 'ok' and created_at > now() - interval '24 hours';
      -- v_net = bets - wins over 24 h = net loss
      if v_cfg.daily_loss_limit > 0 and v_net + p_coin > v_cfg.daily_loss_limit then
        v_reason := 'daily limit reached';
      elsif v_cfg.daily_win_limit > 0 and -v_net >= v_cfg.daily_win_limit then
        v_reason := 'daily limit reached';
      end if;
    end if;
  else
    -- a win: only after a bet on this game recently, and not out of proportion to what was bet
    select coalesce(sum(coin), 0) into v_bets
      from public.game_transactions
     where profile_id = v_session.profile_id and status = 'ok' and type = 0
       and game_type is not distinct from p_game_type
       and created_at > now() - interval '15 minutes';
    if p_coin > 0 and v_bets = 0 then
      v_reason := 'win without a bet';
    elsif p_coin > v_bets * v_cfg.max_payout_multiple then
      v_reason := 'win above the payout limit';
    end if;
  end if;

  if v_reason is not null then
    update public.game_transactions set status = 'rejected', reason = v_reason, balance_after = v_coins where id = v_claimed;
    return jsonb_build_object('ok', false, 'msg', v_reason, 'coin', v_coins, 'id', v_uid);
  end if;

  if p_coin > 0 then
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (v_session.profile_id, case when p_type = 0 then 'game_bet' else 'game_win' end, 'coins',
            case when p_type = 0 then -p_coin else p_coin end, 'game_transactions', v_claimed, left(coalesce(p_game_type, 'game'), 60));
  end if;
  select coins into v_balance from public.wallets where profile_id = v_session.profile_id;
  update public.game_transactions set status = 'ok', reason = 'success', balance_after = v_balance where id = v_claimed;
  return jsonb_build_object('ok', true, 'msg', 'success', 'coin', v_balance, 'id', v_uid);
end;
$$;
revoke execute on function public.game_apply_balance(text, bigint, text, integer, bigint, text, text, bigint, bigint, bigint, text, text)
  from public, anon, authenticated;
grant execute on function public.game_apply_balance(text, bigint, text, integer, bigint, text, text, bigint, bigint, bigint, text, text)
  to service_role;
