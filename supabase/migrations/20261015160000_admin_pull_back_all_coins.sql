-- Master / Super Admin: take back a user's WHOLE coin balance in one step (user profile -> "Pull back all coins").
--
-- Why: pull_back_coin_grant() reverses one specific grant and refuses when the user has spent below it, so there was no way to
-- clear a balance (bought, won or granted) that should not be there. This writes ONE negative 'grant_reversal' ledger row for
-- exactly the coins the wallet holds at that moment (the wallet row is locked first, so the amount cannot go stale), the same
-- ledger kind and the same "reclaimed from your wallet by an admin" push as every other pull-back, plus a critical audit-log row.
--   - a reason (3+ characters) is required and is kept in the ledger note and the audit log
--   - not on your own account, not on a ghost, and a staff account only by a Super Admin
--   - coins only: diamonds are never touched
--   - needs the Master / Super Admin role AND the coins switch (manage_coins, on by default for a Master)
-- A new function with a new name: nothing the apps call changes. Rollback: supabase/rollbacks/20261015160000_down.sql.
create or replace function public.admin_pull_back_all_coins(p_user_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
  v_coins bigint;
  v_ledger uuid;
begin
  if not (public.is_admin_or_above() and public.staff_cap_on('manage_coins')) then
    raise exception 'Only a Master or Super Admin with coin access can pull coins back';
  end if;
  if length(v_reason) < 3 then
    raise exception 'Give a reason (at least 3 characters)';
  end if;
  if p_user_id is null or p_user_id = auth.uid() then
    raise exception 'You cannot pull coins back from your own account';
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_user_id and not coalesce(p.is_ghost, false)) then
    raise exception 'That user does not exist';
  end if;
  if exists (select 1 from public.staff_roles s where s.user_id = p_user_id) and not public.is_super_admin() then
    raise exception 'Only a Super Admin can pull coins back from a staff account';
  end if;

  -- lock the wallet so the amount taken is exactly what it holds now
  select w.coins into v_coins from public.wallets w where w.profile_id = p_user_id for update;
  if not found then
    raise exception 'This user has no wallet';
  end if;
  if coalesce(v_coins, 0) <= 0 then
    raise exception 'This user has no coins to pull back (balance %)', coalesce(v_coins, 0);
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (p_user_id, 'grant_reversal', 'coins', -v_coins, 'profiles', p_user_id, 'Pulled back by admin: ' || left(v_reason, 200))
    returning id into v_ledger;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'coins.pull_back_all', p_user_id::text || ' (' || v_coins || ' coins) ' || left(v_reason, 200), 'critical');

  return jsonb_build_object('user_id', p_user_id, 'coins', v_coins, 'ledger_id', v_ledger);
end;
$$;
revoke execute on function public.admin_pull_back_all_coins(uuid, text) from public, anon;
grant execute on function public.admin_pull_back_all_coins(uuid, text) to authenticated;
