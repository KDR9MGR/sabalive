-- Down script for supabase/migrations/20261009130000_lucky_box_pull_back.sql
-- Applied BY HAND only. Removes the function. Reversals it already made stay in the ledger (they are plain rows
-- and the wallets already reflect them); to undo one of those, add a matching 'grant' row by hand.
drop function if exists public.lucky_box_pull_back(uuid);
