-- coin_grants was select-able only by the recipient or an admin — a
-- coin_minters-listed agency_manager/sub_admin who distributes coins to
-- one of their hosts (via distribute_coins) couldn't see their own past
-- grants afterwards. Adds a second, additive SELECT policy so a granter
-- can see grants they made; RLS policies combine with OR, so recipients
-- and admins keep exactly the access they already had.
create policy "Granters see coin grants they made"
  on public.coin_grants for select using (granted_by = auth.uid());

-- coin_treasury itself was admin-only to read, so a coin_minters-listed
-- agency_manager/sub_admin could call distribute_coins but never see the
-- balance they were distributing from. can_mint_coins() already governs
-- who may call that RPC; extend read access to match.
create policy "Minters read the treasury balance"
  on public.coin_treasury for select using (public.can_mint_coins());
