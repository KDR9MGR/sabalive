-- Undoes 20261102100000_staff_see_only_their_chain: back to "a Global Admin sees the whole tree and every staff list shows everyone".
-- (If you only want to pause the rule, switch off  Release Settings -> "Limit each admin to their own chain"  instead: nothing is deleted.)
set local lock_timeout = '5s';

drop policy if exists "Scoped staff see their own chain" on public.profiles;
drop policy if exists "Scoped staff see their own chain" on public.host_profiles;
drop policy if exists "Scoped staff see their own chain" on public.agencies;
drop policy if exists "Scoped staff see their own chain" on public.staff_roles;
drop policy if exists "Scoped staff see their own chain" on public.wallets;
drop policy if exists "Scoped staff see their own chain" on public.coin_transfers;

-- the three function bodies as they were (20260930160000 and 20260930180000)
create or replace function public.manages_agency(target_agency_id uuid)
returns boolean language sql stable
as $$
  select coalesce(
    public.is_admin_or_above()
      or (public.current_staff_role() in ('agency_manager', 'sub_admin')
          and public.current_agency_id() = target_agency_id)
      or (public.current_staff_role() = 'sub_admin'
          and public.owns_agency(target_agency_id))
      or (public.current_staff_role() = 'country_admin'
          and public.country_owns_agency(target_agency_id))
      or public.current_staff_role() = 'global_admin',
    false
  );
$$;

create or replace function public.in_country_scope_agency(p_agency_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce(
    public.is_global_scope()
    or (public.current_staff_role() = 'country_admin' and public.country_owns_agency(p_agency_id)),
    false);
$$;

create or replace function public.staff_emails(p_user_ids uuid[])
returns table (user_id uuid, email text)
language sql stable security definer set search_path = public, auth
as $$
  select u.id, u.email::text
    from auth.users u
   where u.id = any(coalesce(p_user_ids, '{}'::uuid[]))
     and (
       u.id = auth.uid()
       or public.is_admin_or_above()
       or (public.current_staff_role() = 'global_admin'
           and exists (select 1 from public.staff_roles s
                        where s.user_id = u.id
                          and s.role in ('country_admin', 'sub_admin', 'agency_manager')))
       or (public.current_staff_role() = 'country_admin'
           and (public.owns_sub_admin(u.id)
                or exists (select 1 from public.staff_roles s
                            where s.user_id = u.id and s.role = 'agency_manager'
                              and s.agency_id is not null
                              and public.country_owns_agency(s.agency_id))))
       or (public.current_staff_role() = 'sub_admin'
           and exists (select 1 from public.staff_roles s
                        where s.user_id = u.id and s.role = 'agency_manager'
                          and s.agency_id is not null
                          and public.owns_agency(s.agency_id)))
     );
$$;

drop function if exists public.find_user_for_coins(bigint);
drop function if exists public.staff_visible_profile_ids();
drop function if exists public.staff_chain_profile_ids();
drop function if exists public.staff_visible_staff_ids();
drop function if exists public.staff_downline_ids();
drop function if exists public.staff_managed_agency_ids();
drop function if exists public.global_owns_agency(uuid);
drop function if exists public.staff_scope_applies();
drop function if exists public.staff_scope_limited();
