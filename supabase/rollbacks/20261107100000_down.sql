-- Down script for supabase/migrations/20261107100000_game_win_notices.sql
-- Applied BY HAND only. Removes the game-win notice feed: the trigger on game_transactions, its two functions and the table (the few recent notice rows are deleted; nothing
-- else is touched, game payouts and ledgers are not affected). An app that already listens for the feed just stops hearing about wins (it fails open to "nothing to show").
begin;
set local lock_timeout = '5s';
drop trigger if exists game_transactions_win_notice on public.game_transactions;
drop function if exists public._game_win_notice_after_win();
drop table if exists public.game_win_notices;
drop function if exists public.game_win_notice_min_coins();
commit;
