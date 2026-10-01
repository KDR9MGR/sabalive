-- Fixes a regression from earlier today (20260930210000): when adding
-- 'grant_reversal' to wallet_ledger_kind_check, that migration re-emitted
-- the constraint from an out-of-date list and silently dropped
-- 'transfer_in', 'transfer_out' (added 20260924100000, used by
-- transfer_coins_down ever since) and 'store_purchase' (also
-- 20260924100000, used by purchase_store_item). Since that push, every
-- wallet-to-wallet transfer (Global Admin -> Country Admin -> Sub Admin ->
-- Agency -> User) and every store purchase has been failing with a check
-- constraint violation. Restoring the full set.
alter table public.wallet_ledger drop constraint wallet_ledger_kind_check;
alter table public.wallet_ledger add constraint wallet_ledger_kind_check
  check (kind in ('purchase', 'gift_sent', 'gift_received', 'grant', 'withdrawal',
                   'transfer_in', 'transfer_out', 'store_purchase', 'grant_reversal'));
