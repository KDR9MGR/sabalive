-- Each staff level sees only the people in its own chain (Global > Country > Sub Admin > Agency > Host). Master and Super Admin still see everyone.
--
-- WHAT WAS WRONG. "profiles" and "host_profiles" are readable by every signed-in account (the app needs that to show people), and the staff tables
-- gave a Global Admin the whole tree. So the Users / Hosts / Agencies / Admin lists of a Global, Country, Sub Admin or Agency panel showed EVERYONE on
-- the platform, not the people assigned to them.
--
-- WHAT THIS DOES. It adds the rule as RESTRICTIVE row policies (they only ever narrow what the existing policies allow; none is dropped or changed) on
-- profiles, host_profiles, agencies, staff_roles, wallets and coin_transfers, for the four scoped roles only. Every other account (app users, Master,
-- Super Admin, ghosts, the app's own reads) is untouched: the rule starts with "does this apply to me?" and for them the answer is a plain no.
-- What a scoped account sees, by role (all of it read-only visibility; nothing here moves or changes any data):
--   * itself, the staff above it that it reports to, and (Global / Country only) peers of its own rank, because the Transfer pages pick them
--   * everyone below it: Global -> its Country Admins (staff_roles.global_admin_id) -> their Sub Admins (country_admin_id) -> the agencies they own
--     (agencies.sub_admin_id) -> those agencies' managers and hosts, plus people who applied to those agencies
--   * anyone named on a coin transfer it can see (so coin history still shows names). Ordinary users who are not hosts are otherwise hidden.
-- Hosts with no agency yet are seen by Master / Super Admin only.
--
-- THE SWITCH. Everything is OFF until Super Admin turns on  Application Config -> Release Settings -> "Limit each admin to their own chain"
-- (app_config.feature_flags.limit_staff_to_own_chain). Off = exactly today's behaviour; on = the rule above. It is read once per query, so it takes effect
-- at once in both directions, with no deploy. IMPORTANT before turning it on: a Global Admin only sees Country Admins that are assigned to them
-- (staff_roles.global_admin_id, set on the Transfer Global page); one that is not assigned to any Global Admin is seen by Master / Super Admin only.
--
-- manages_agency() and in_country_scope_agency() (the rule behind host lists, applications, live requests, salary reports, transfers) get one change:
-- the global_admin branch used to say "every agency"; with the switch on it says "agencies in my chain". Nothing else in them changes.
-- Also new: find_user_for_coins(), so a coin sender can still reach an ordinary user by typing the exact app User ID (without browsing everyone).
--
-- Additive: new functions and restrictive policies only; two function bodies (manages_agency, in_country_scope_agency) and staff_emails gain the switch.
-- Rollback: supabase/rollbacks/20261102100000_down.sql.
set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------------------- the switch
create or replace function public.staff_scope_limited()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select feature_flags -> 'limit_staff_to_own_chain' = 'true'::jsonb from public.app_config where id), false);
$$;
revoke execute on function public.staff_scope_limited() from public, anon;
grant execute on function public.staff_scope_limited() to authenticated;

-- true only for a Global / Country / Sub Admin / Agency account, and only while the switch is on
create or replace function public.staff_scope_applies()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.staff_scope_limited()
                  and public.current_staff_role() in ('global_admin', 'country_admin', 'sub_admin', 'agency_manager'), false);
$$;
revoke execute on function public.staff_scope_applies() from public, anon;
grant execute on function public.staff_scope_applies() to authenticated;

-- ------------------------------------------------------------------------------------------------------------------------------ agencies in my chain
create or replace function public.global_owns_agency(p_agency_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    exists (select 1
              from public.agencies a
              join public.staff_roles sa on sa.user_id = a.sub_admin_id and sa.role = 'sub_admin'
              join public.staff_roles ca on ca.user_id = sa.country_admin_id and ca.role = 'country_admin'
             where a.id = p_agency_id
               and ca.global_admin_id = auth.uid()),
    false);
$$;
revoke execute on function public.global_owns_agency(uuid) from public, anon;
grant execute on function public.global_owns_agency(uuid) to authenticated;

-- same body as before, except the global_admin branch: every agency while the switch is off, the agencies in its chain while it is on
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
      or (public.current_staff_role() = 'global_admin'
          and (not public.staff_scope_limited() or public.global_owns_agency(target_agency_id))),
    false
  );
$$;

create or replace function public.in_country_scope_agency(p_agency_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce(
    public.is_admin_or_above()
    or (public.current_staff_role() = 'country_admin' and public.country_owns_agency(p_agency_id))
    or (public.current_staff_role() = 'global_admin'
        and (not public.staff_scope_limited() or public.global_owns_agency(p_agency_id))),
    false);
$$;

-- the agencies the caller manages (one pass per query; the row policies below read it)
create or replace function public.staff_managed_agency_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select a.id from public.agencies a where public.manages_agency(a.id);
$$;
revoke execute on function public.staff_managed_agency_ids() from public, anon;
grant execute on function public.staff_managed_agency_ids() to authenticated;

-- ------------------------------------------------------------------------------------------------------------------------- staff below me (and me)
create or replace function public.staff_downline_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  with me as (
    select user_id, role, agency_id from public.staff_roles where user_id = auth.uid()
  ),
  ag as (select public.staff_managed_agency_ids() as id)
  select user_id from me
  union
  select s.user_id
    from public.staff_roles s, me m
   where (m.role = 'global_admin' and s.role = 'country_admin' and s.global_admin_id = m.user_id)
      or (m.role = 'global_admin' and s.role = 'sub_admin'
          and s.country_admin_id in (select c.user_id from public.staff_roles c where c.role = 'country_admin' and c.global_admin_id = m.user_id))
      or (m.role = 'country_admin' and s.role = 'sub_admin' and s.country_admin_id = m.user_id)
      or (m.role in ('global_admin', 'country_admin', 'sub_admin') and s.role = 'agency_manager' and s.agency_id in (select id from ag))
      or (m.role = 'agency_manager' and s.role = 'agency_manager' and s.agency_id = m.agency_id);
$$;
revoke execute on function public.staff_downline_ids() from public, anon;
grant execute on function public.staff_downline_ids() to authenticated;

-- ---------------------------------------------------------------------------------------- staff I can see in a list (below me, above me, my peers)
create or replace function public.staff_visible_staff_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  with me as (
    select user_id, role, agency_id, country_admin_id, global_admin_id from public.staff_roles where user_id = auth.uid()
  )
  select public.staff_downline_ids()
  union
  -- the staff above me that I report to
  select m.country_admin_id from me m where m.role = 'sub_admin' and m.country_admin_id is not null
  union
  select m.global_admin_id from me m where m.role = 'country_admin' and m.global_admin_id is not null
  union
  select a.sub_admin_id from public.agencies a join me m on m.role = 'agency_manager' and a.id = m.agency_id where a.sub_admin_id is not null
  union
  -- peers of my own rank (the Transfer pages pick them)
  select s.user_id from public.staff_roles s join me m on m.role in ('global_admin', 'country_admin') and s.role = m.role;
$$;
revoke execute on function public.staff_visible_staff_ids() from public, anon;
grant execute on function public.staff_visible_staff_ids() to authenticated;

-- ---------------------------------------------------------------------------------- people in my chain (staff below me, hosts, applicants, coin contacts)
create or replace function public.staff_chain_profile_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  with ag as (select public.staff_managed_agency_ids() as id),
       dl as (select public.staff_downline_ids() as id)
  select id from dl
  union
  select h.profile_id from public.host_profiles h where h.agency_id in (select id from ag)
  union
  select ha.applicant_id from public.host_applications ha where ha.agency_id in (select id from ag)
  union
  -- everyone named on a coin transfer by me, to me, by someone below me or inside one of my agencies (so coin history shows names)
  select t.recipient_id from public.coin_transfers t where t.sender_id in (select id from dl)
  union
  select t.sender_id from public.coin_transfers t where t.recipient_id in (select id from dl)
  union
  select t.recipient_id from public.coin_transfers t where t.agency_id in (select id from ag)
  union
  select t.sender_id from public.coin_transfers t where t.agency_id in (select id from ag);
$$;
revoke execute on function public.staff_chain_profile_ids() from public, anon;
grant execute on function public.staff_chain_profile_ids() to authenticated;

-- ------------------------------------------------------------------------------------------------------------------------------- profiles I can see
create or replace function public.staff_visible_profile_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select public.staff_chain_profile_ids()
  union
  select public.staff_visible_staff_ids();
$$;
revoke execute on function public.staff_visible_profile_ids() from public, anon;
grant execute on function public.staff_visible_profile_ids() to authenticated;

-- ------------------------------------------------------------------------------------------------------------ the rule, as narrowing row policies
drop policy if exists "Scoped staff see their own chain" on public.profiles;
create policy "Scoped staff see their own chain" on public.profiles
  as restrictive for select to authenticated
  using (not (select public.staff_scope_applies()) or id in (select public.staff_visible_profile_ids()));

drop policy if exists "Scoped staff see their own chain" on public.host_profiles;
create policy "Scoped staff see their own chain" on public.host_profiles
  as restrictive for select to authenticated
  using (not (select public.staff_scope_applies())
         or profile_id = auth.uid()
         or agency_id in (select public.staff_managed_agency_ids()));

drop policy if exists "Scoped staff see their own chain" on public.agencies;
create policy "Scoped staff see their own chain" on public.agencies
  as restrictive for select to authenticated
  using (not (select public.staff_scope_applies())
         or manager_id = auth.uid()
         or id in (select public.staff_managed_agency_ids()));

drop policy if exists "Scoped staff see their own chain" on public.staff_roles;
create policy "Scoped staff see their own chain" on public.staff_roles
  as restrictive for select to authenticated
  using (not (select public.staff_scope_applies()) or user_id in (select public.staff_visible_staff_ids()));

drop policy if exists "Scoped staff see their own chain" on public.wallets;
create policy "Scoped staff see their own chain" on public.wallets
  as restrictive for select to authenticated
  using (not (select public.staff_scope_applies()) or profile_id in (select public.staff_chain_profile_ids()));

drop policy if exists "Scoped staff see their own chain" on public.coin_transfers;
create policy "Scoped staff see their own chain" on public.coin_transfers
  as restrictive for select to authenticated
  using (not (select public.staff_scope_applies())
         or sender_id in (select public.staff_downline_ids())
         or recipient_id in (select public.staff_downline_ids())
         or agency_id in (select public.staff_managed_agency_ids()));

-- -------------------------------------------------------------------------------------------------------------- staff emails (explicit id list)
-- Same function; only the global_admin branch changes: with the switch on it is limited to staff in its own chain.
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
                          and s.role in ('country_admin', 'sub_admin', 'agency_manager'))
           and (not public.staff_scope_limited() or u.id in (select public.staff_visible_staff_ids())))
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

-- ----------------------------------------------------------------------------------------------------------------- reaching one person by their ID
-- A coin sender (Global, Country, Sub Admin, Agency, Master, Super Admin) can still send coins to an ordinary user, who is not in their list, by typing
-- the exact app User ID. This returns that one person's name and IDs, nothing else, and never a ghost. It does not let anyone browse.
create or replace function public.find_user_for_coins(p_display_id bigint)
returns table (id uuid, name text, username text, display_id bigint)
language sql stable security definer set search_path = public
as $$
  select p.id, p.name, p.username, p.display_id
    from public.profiles p
   where p.display_id = p_display_id
     and not p.is_ghost
     and public.current_staff_role() in ('super_admin', 'admin', 'global_admin', 'country_admin', 'sub_admin', 'agency_manager')
   limit 1;
$$;
revoke execute on function public.find_user_for_coins(bigint) from public, anon;
grant execute on function public.find_user_for_coins(bigint) to authenticated;
