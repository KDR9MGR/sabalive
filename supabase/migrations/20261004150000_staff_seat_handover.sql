-- Master -> User Management transfers: hand a panel account's seat to another
-- existing user. The chosen user takes the staff role AND everything the old
-- account owned (the sub admins / agencies / hosts under it, its agency, and its
-- coin balance); the old account loses the role and becomes an ordinary user.
-- The new holder keeps their own login. Master only, for Global / Country / Sub
-- Admin and Agency accounts. (A host isn't a panel account, so it has no handover.)
--
-- NOTE: becoming staff means the account can no longer use the consumer app (staff
-- accounts are refused there); the panel says so before confirming.
create or replace function public.master_handover_staff_seat(p_from uuid, p_to uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.staff_roles%rowtype;
  v_coins bigint;
  v_agencies integer;
  v_owned integer;
begin
  if v_actor is null then raise exception 'Sign in first'; end if;
  if public.current_staff_role() is distinct from 'admin' then
    raise exception 'Only a Master can hand a panel account to another user';
  end if;
  if p_from = p_to then raise exception 'Choose a different user'; end if;

  select * into v_row from public.staff_roles where user_id = p_from for update;
  if not found then raise exception 'That account has no panel role'; end if;
  if not public.can_manage_staff_role('admin', v_row.role) then
    raise exception 'You are not allowed to hand over this account';
  end if;

  if not exists (select 1 from public.profiles where id = p_to) then
    raise exception 'That user does not exist';
  end if;
  if exists (select 1 from public.staff_roles where user_id = p_to) then
    raise exception 'That user already has a panel role';
  end if;
  if public.is_ghost(p_to) then raise exception 'A ghost account cannot take a panel seat'; end if;

  -- the seat: delete + insert (not an UPDATE of the key) so the app-metadata staff flag
  -- is cleared on the old account and set on the new one
  delete from public.staff_roles where user_id = p_from;
  insert into public.staff_roles (user_id, role, agency_id, permissions, country_admin_id)
  values (p_to, v_row.role, v_row.agency_id, v_row.permissions, v_row.country_admin_id);

  -- what it owned
  update public.agencies set sub_admin_id = p_to where sub_admin_id = p_from;
  get diagnostics v_agencies = row_count;
  update public.agencies set manager_id = p_to where manager_id = p_from;
  update public.staff_roles set country_admin_id = p_to where country_admin_id = p_from;
  get diagnostics v_owned = row_count;
  update public.assignments set sub_admin_id = p_to
   where sub_admin_id = p_from
     and not exists (select 1 from public.assignments a2
                      where a2.host_id = assignments.host_id and a2.sub_admin_id = p_to);

  -- its coin balance
  select coins into v_coins from public.wallets where profile_id = p_from;
  if coalesce(v_coins, 0) > 0 then
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (p_from, 'transfer_out', 'coins', -v_coins, 'staff_roles', 'Panel seat handed over'),
           (p_to, 'transfer_in', 'coins', v_coins, 'staff_roles', 'Panel seat received');
  end if;

  insert into public.audit_logs (actor_id, action, target, severity)
  values (v_actor, 'staff.seat_handed_over', p_from::text || ' -> ' || p_to::text || ' (' || v_row.role::text || ')', 'critical');

  return jsonb_build_object('role', v_row.role, 'agencies', v_agencies, 'sub_admins', v_owned, 'coins', coalesce(v_coins, 0));
end;
$$;
revoke execute on function public.master_handover_staff_seat(uuid, uuid) from public, anon;
grant execute on function public.master_handover_staff_seat(uuid, uuid) to authenticated;
