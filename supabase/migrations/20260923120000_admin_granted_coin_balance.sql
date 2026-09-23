-- Wallet & Earnings should only reflect coins the platform actually
-- distributed to a user via the admin panel (kind='grant'), not coins
-- from a self-serve purchase (kind='purchase', currently dev-only anyway)
-- or a coin-seller/reseller transfer (kind='transfer_in'/'transfer_out',
-- resell_coins). wallets.coins itself is left untouched — it's the real,
-- true spendable balance every RPC (send_gift, claim_seat's mic publish
-- path, etc.) checks against, and must keep including every source.
-- This is a display-only aggregate for that one screen.
--
-- gift_sent stays counted (a negative entry) since it's real spending
-- activity, not a coin source — but that means a user who funded gifts
-- with purchased/reseller coins can drive this filtered figure below
-- zero (confirmed against live data: one profile does). GREATEST(0, ...)
-- floors it rather than showing a negative balance.
create function public.admin_granted_coin_balance()
returns bigint
language sql stable security definer set search_path = public
as $$
  select greatest(0, coalesce(sum(amount) filter (
    where kind not in ('purchase', 'transfer_in', 'transfer_out')
  ), 0))
  from public.wallet_ledger
  where profile_id = auth.uid() and currency = 'coins';
$$;
