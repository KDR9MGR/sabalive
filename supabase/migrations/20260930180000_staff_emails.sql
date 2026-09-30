-- The admin lists show each staff member's email, but email lives only in
-- auth.users, which the panel (anon key) can't read. This returns emails ONLY
-- for accounts the caller is allowed to see, using the same tree as the rest of
-- the hierarchy:
--   super / admin   any account
--   global_admin    country admins, sub admins, agency managers
--   country_admin   their own sub admins, and managers of agencies in their tree
--   sub_admin       managers of agencies they own
--   anyone          their own email
-- It is a read-only lookup by explicit id list (no "list everyone" mode).

create function public.staff_emails(p_user_ids uuid[])
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

revoke execute on function public.staff_emails(uuid[]) from public, anon;
grant execute on function public.staff_emails(uuid[]) to authenticated;
