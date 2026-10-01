-- Super Admin's Distribute flow could previously only send coins to every
-- Master account at once (p_audience='role', p_role='admin'). Add the
-- ability to pick one specific Master account by ID/username instead, using
-- the distribute_coins RPC's existing p_audience='users' path — just need
-- the super_admin restriction (20261001110000) to also accept that mode,
-- as long as every id in p_recipient_ids actually is a Master account.
-- Re-emitting the live body verbatim (pulled via pg_get_functiondef) with
-- only that one check block changed.
create or replace function public.distribute_coins(
  p_per_recipient bigint,
  p_audience text,
  p_role text default null,
  p_recipient_ids uuid[] default null,
  p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_ids uuid[];
  v_count integer;
  v_total bigint;
  v_balance bigint;
begin
  if not public.can_mint_coins() then
    raise exception 'Not allowed to distribute coins';
  end if;

  if public.current_staff_role() = 'super_admin' then
    if p_audience = 'role' and p_role = 'admin' then
      null; -- every Master account — fine
    elsif p_audience = 'users' and coalesce(array_length(p_recipient_ids, 1), 0) > 0
      and not exists (
        select 1 from unnest(p_recipient_ids) rid
        where not exists (select 1 from public.staff_roles s where s.user_id = rid and s.role = 'admin')
      ) then
      null; -- a hand-picked set of Master accounts — fine
    else
      raise exception 'A Super Admin may only distribute coins to Master accounts';
    end if;
  end if;

  if p_per_recipient is null or p_per_recipient <= 0 then
    raise exception 'Amount per recipient must be positive';
  end if;
  if p_per_recipient > 2147483647 then
    raise exception 'Amount per recipient is too large';
  end if;

  select array_agg(id) into v_ids from (
    select p.id
    from public.profiles p
    where case p_audience
      when 'all' then true
      when 'users' then p.id = any(coalesce(p_recipient_ids, '{}'::uuid[]))
      when 'role' then case p_role
        when 'host'          then p.is_host
        when 'agency'        then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'agency_manager')
        when 'sub_admin'     then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'sub_admin')
        when 'country_admin' then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'country_admin')
        when 'global_admin'  then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'global_admin')
        when 'admin'         then exists (select 1 from public.staff_roles s where s.user_id = p.id and s.role = 'admin')
        when 'staff'         then exists (select 1 from public.staff_roles s where s.user_id = p.id)
        else false end
      else false end
  ) t;

  v_count := coalesce(array_length(v_ids, 1), 0);
  if v_count = 0 then
    raise exception 'No recipients matched';
  end if;

  v_total := v_count::bigint * p_per_recipient;

  select (minted_total - distributed_total) into v_balance from public.coin_treasury where id = true;
  if v_total > v_balance then
    raise exception 'Treasury balance % is short of the % coins this distribution needs', v_balance, v_total;
  end if;

  insert into public.wallets (profile_id)
    select unnest(v_ids) on conflict (profile_id) do nothing;

  insert into public.coin_grants (granted_to, granted_by, coins, note)
    select unnest(v_ids), auth.uid(), p_per_recipient::integer,
           coalesce(nullif(trim(p_note), ''), 'Treasury distribution');

  update public.coin_treasury
    set distributed_total = distributed_total + v_total,
        updated_at = now(),
        updated_by = auth.uid()
    where id = true;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'treasury.distribute', p_audience || coalesce(':' || p_role, '') || ' x' || v_count, 'info');

  return jsonb_build_object('recipients', v_count, 'total', v_total,
    'balance', v_balance - v_total);
end;
$$;
