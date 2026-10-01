-- The coin_treasury singleton row (seeded by its own migration,
-- 20260908090500) is missing in production — something deleted it since,
-- outside of any RPC (there's no delete policy; only a direct superuser
-- query could have). Two real consequences while it was gone:
--   1. Super Admin's Coin Treasury page crashed outright: getTreasury()'s
--      .single() throws on zero rows ("Cannot coerce the result to a
--      single JSON object").
--   2. mint_coins()/distribute_coins()'s own balance check silently no-op'd
--      instead of enforcing anything: `... where id = true` touched zero
--      rows, and `v_total > v_balance` is NULL (not true) when v_balance is
--      NULL from the SELECT INTO finding nothing — so every distribution
--      this session went through without ever being weighed against a cap.
-- Restoring it at zero (not attempting to reconstruct a historical total —
-- that's guesswork the CHECK constraints would likely reject anyway).
-- Super Admin should "Generate coins" for a real starting balance before
-- distributing further.
insert into public.coin_treasury (id) values (true)
  on conflict (id) do nothing;
