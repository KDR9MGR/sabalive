-- Which Global Admin a Country Admin reports to: the link the Salary exports (and the panel's Transfer Global page) were waiting for.
--
-- The ladder is Global Admin > Country Admin > Sub Admin > Agency, and agencies.sub_admin_id and staff_roles.country_admin_id (sub admins) already record the
-- bottom two steps. The top step was never stored: salary_agency_map() reads staff_roles.global_admin_id "IF that field exists" (20261022100000) and the panel's
-- Transfer Global page reads the same field and calls transfer_country_admin(), but neither the column nor the function was ever created, so every Global Admin
-- column in the exports was empty and "Owned by Global Admin" said Unassigned for everyone. This migration makes them real:
--   1. staff_roles.global_admin_id (nullable; no foreign key on purpose: a foreign key to profiles would lock that busy table, and every reader joins it with a LEFT
--      JOIN, so a Global Admin who was removed simply shows as not assigned).
--   2. A one-time back-fill from the audit log: a Country Admin created by someone who is a Global Admin now belongs to that Global Admin. Those created by a
--      Master or Super Admin stay unassigned (nothing records which Global Admin they belong under): assign them in the panel, Transfer Global.
--   3. From now on, a Country Admin created by a Global Admin is linked to them automatically (an AFTER INSERT trigger on the 'staff.created' audit row that
--      create_staff_account writes; create_staff_account itself is not touched). The trigger can never make creating an account fail.
--   4. transfer_country_admin(country_admin, to_global_admin): assigns or moves a Country Admin (and with them their Sub Admins, Agencies and Hosts, which hang
--      off the Country Admin) under another Global Admin. Master and Super Admin can move any; a Global Admin only their own.
-- salary_agency_map() and the exports need no change: they already read the column through to_jsonb(), so they start filling in the moment it exists.
-- NOTE: this records who reports to whom for reporting; it does not change who can SEE what (Global Admins keep seeing the whole tree, as before).
--
-- Additive (a nullable column without a default, a trigger, two functions). Rollback: supabase/rollbacks/20261026100000_down.sql.
alter table public.staff_roles add column if not exists global_admin_id uuid;

-- 2. back-fill: the creator of each Country Admin, when that creator is a Global Admin now
update public.staff_roles s
   set global_admin_id = c.actor_id
  from (
    select distinct on (target_id) target_id, actor_id
      from (
        select a.actor_id, left(a.target, 36)::uuid as target_id, a.created_at
          from public.audit_logs a
         where a.action = 'staff.created'
           and a.actor_id is not null
           and a.target ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} -> country_admin$'
      ) x
     order by target_id, created_at desc
  ) c
 where s.user_id = c.target_id
   and s.role = 'country_admin'
   and s.global_admin_id is null
   and exists (select 1 from public.staff_roles g where g.user_id = c.actor_id and g.role = 'global_admin');

-- 3. a Country Admin created by a Global Admin belongs to them from the start
create or replace function public.link_new_country_admin_to_global()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  begin
    if new.actor_id is not null
       and new.target ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} -> country_admin$'
       and exists (select 1 from public.staff_roles g where g.user_id = new.actor_id and g.role = 'global_admin') then
      update public.staff_roles
         set global_admin_id = new.actor_id
       where user_id = left(new.target, 36)::uuid and role = 'country_admin' and global_admin_id is null;
    end if;
  exception when others then
    null; -- linking is a convenience: it must never stop a staff account from being created
  end;
  return new;
end;
$$;
revoke execute on function public.link_new_country_admin_to_global() from public, anon, authenticated;

drop trigger if exists audit_logs_link_country_admin on public.audit_logs;
create trigger audit_logs_link_country_admin
  after insert on public.audit_logs
  for each row when (new.action = 'staff.created')
  execute function public.link_new_country_admin_to_global();

-- 4. assign / move a Country Admin under a Global Admin
create or replace function public.transfer_country_admin(p_country_admin_id uuid, p_to_global_admin uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_role public.staff_role := public.current_staff_role();
  v_owner uuid;
begin
  if v_role is null or v_role not in ('super_admin', 'admin', 'global_admin') then
    raise exception 'Only a Master, Super Admin or Global Admin can transfer a Country Admin';
  end if;
  if not exists (select 1 from public.staff_roles where user_id = p_country_admin_id and role = 'country_admin') then
    raise exception 'That account is not a country admin';
  end if;
  if not exists (select 1 from public.staff_roles where user_id = p_to_global_admin and role = 'global_admin') then
    raise exception 'The receiving account is not a global admin';
  end if;
  select global_admin_id into v_owner from public.staff_roles where user_id = p_country_admin_id;
  if v_role = 'global_admin' and v_owner is distinct from auth.uid() then
    raise exception 'That country admin is not one of yours';
  end if;
  if v_owner is not distinct from p_to_global_admin then
    raise exception 'That country admin already belongs to this global admin';
  end if;

  update public.staff_roles set global_admin_id = p_to_global_admin where user_id = p_country_admin_id;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'country_admin.transfer', p_country_admin_id::text || ' -> ' || p_to_global_admin::text, 'warning');
end;
$$;
revoke execute on function public.transfer_country_admin(uuid, uuid) from public, anon;
grant execute on function public.transfer_country_admin(uuid, uuid) to authenticated;
