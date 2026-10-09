-- Lucky Box: "pull back" a reward that was already paid.
--
-- A Master can take a Lucky Box win back from the host's wallet (a paid-out mistake, a host who cheated the streak).
-- It mirrors pull_back_coin_grant: a negative 'grant_reversal' ledger row for the same diamonds, tied to the
-- original row so it can only happen once, refused (with the numbers) when the host has already spent or withdrawn
-- the diamonds, and written to the audit log. The original 'lucky_box' row stays, which is what stops the cron job
-- from paying the same stream a second time; the reversal row is NOT tagged 'lucky_box' for the same reason.
--
-- Additive: one new function. Nothing the apps call changes.
create or replace function public.lucky_box_pull_back(p_ledger_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.wallet_ledger;
  v_balance bigint;
begin
  if not (public.is_admin_or_above() and public.staff_cap_on('manage_lucky_box')) then
    raise exception 'Only a Master or Super admin with Lucky Box access can pull back a reward';
  end if;

  -- lock the reward row so two admins pressing the button cannot both reverse it
  select * into v_row from public.wallet_ledger
   where id = p_ledger_id and kind = 'grant' and note = 'lucky_box'
   for update;
  if v_row.id is null then
    raise exception 'Lucky Box reward not found';
  end if;

  if exists (
    select 1 from public.wallet_ledger
     where reference_table = 'wallet_ledger' and reference_id = v_row.id and kind = 'grant_reversal'
  ) then
    raise exception 'This reward has already been pulled back';
  end if;

  select diamonds into v_balance from public.wallets where profile_id = v_row.profile_id;
  if coalesce(v_balance, 0) < v_row.amount then
    raise exception 'Cannot pull back — the host only has % diamonds left of the % won', coalesce(v_balance, 0), v_row.amount;
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, reference_id, note)
    values (v_row.profile_id, 'grant_reversal', v_row.currency, -v_row.amount, 'wallet_ledger', v_row.id,
            'Pulled back: Lucky Box reward');

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'lucky_box.pull_back', v_row.id::text, 'warning');
end;
$$;

-- Supabase hands EXECUTE to anon explicitly on new functions, which "from public" does not remove
revoke execute on function public.lucky_box_pull_back(uuid) from public, anon;
grant execute on function public.lucky_box_pull_back(uuid) to authenticated;
