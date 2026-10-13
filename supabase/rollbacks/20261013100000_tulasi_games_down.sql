-- Down script for supabase/migrations/20261013100000_tulasi_games.sql
-- Applied BY HAND only. Removes the game tables and functions. Game audit rows (game_transactions) are lost; the wallet
-- ledger rows the games wrote stay (they are the wallet's own history). If any ledger row of kind game_bet / game_win
-- exists, those two kinds stay in wallet_ledger_kind_check (removing them would make the table invalid).
begin;
set local lock_timeout = '5s';

drop view if exists public.game_player_day_totals;
drop function if exists public.game_apply_balance(text, bigint, text, integer, bigint, text, text, bigint, bigint, bigint, text, text);
drop function if exists public.game_get_user(text);
drop function if exists public.start_game_session(text);
drop function if exists public._games_enabled();
drop table if exists public.game_transactions;
drop table if exists public.game_sessions;
drop table if exists public.game_players;
drop table if exists public.game_config;

do $$
declare
  v_def text;
  v_new text;
begin
  if exists (select 1 from public.wallet_ledger where kind in ('game_bet', 'game_win')) then
    raise notice 'wallet_ledger still has game_bet / game_win rows: both kinds stay in wallet_ledger_kind_check';
    return;
  end if;
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conname = 'wallet_ledger_kind_check' and c.conrelid = 'public.wallet_ledger'::regclass;
  if v_def is null or v_def not like '%game_bet%' then
    return;
  end if;
  v_new := replace(v_def, ', ''game_bet''::text, ''game_win''::text', '');
  if v_new = v_def then
    raise exception 'could not remove the game kinds from: %', v_def;
  end if;
  alter table public.wallet_ledger drop constraint wallet_ledger_kind_check;
  execute 'alter table public.wallet_ledger add constraint wallet_ledger_kind_check ' || v_new || ' not valid';   -- no full-table scan under the lock
end $$;
commit;
