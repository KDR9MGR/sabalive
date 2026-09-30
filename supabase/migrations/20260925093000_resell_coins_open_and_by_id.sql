-- Two changes to the coin-reseller flow, per Rey:
-- 1. No longer gated behind a reseller access code — any signed-in user can
--    sell/transfer their own coins to another user. The reseller_codes/
--    reseller_grants system itself is left in place (untouched, still used
--    for whatever the admin panel does with it) — this only removes the
--    requirement from the actual transfer path.
-- 2. Recipients are found by their real display_id (the "ID: ..." shown/
--    copied everywhere), not username — usernames haven't been shown to
--    users anywhere in the app since the display_id migration, so the old
--    "enter their @username" flow was no longer something a user could
--    actually do.
create or replace function public.resell_coins(p_recipient text, p_coins integer, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_to uuid;
  v_to_id bigint;
  v_bal bigint;
  v_note text := nullif(trim(p_note), '');
begin
  if v_me is null then raise exception 'Sign in first'; end if;
  if p_coins is null or p_coins <= 0 then raise exception 'Enter a valid amount'; end if;

  begin
    v_to_id := trim(p_recipient)::bigint;
  exception when others then
    raise exception 'Enter a valid recipient ID';
  end;

  select id into v_to from public.profiles where display_id = v_to_id;
  if v_to is null then raise exception 'No user matches ID "%"', p_recipient; end if;
  if v_to = v_me then raise exception 'You cannot sell coins to yourself'; end if;

  select coins into v_bal from public.wallets where profile_id = v_me;
  if coalesce(v_bal, 0) < p_coins then raise exception 'Not enough coins in your balance'; end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
    values (v_me, 'transfer_out', 'coins', -p_coins, coalesce(v_note, 'Coin sale'));
  insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
    values (v_to, 'transfer_in', 'coins', p_coins, 'Coins from a reseller');
  insert into public.coin_transfers (sender_id, recipient_id, coins, note)
    values (v_me, v_to, p_coins, v_note);

  return jsonb_build_object('ok', true, 'coins', p_coins);
end;
$$;
