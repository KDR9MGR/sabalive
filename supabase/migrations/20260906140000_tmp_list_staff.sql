-- TEMP diagnostic: list staff accounts (role + who). Dropped in the next migration.
create function public.tmp_list_staff()
returns jsonb language sql stable security definer set search_path = public, auth
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', sr.user_id,
    'role', sr.role,
    'agency_id', sr.agency_id,
    'name', p.name,
    'username', p.username,
    'email', u.email,
    'created_at', sr.created_at
  ) order by sr.created_at), '[]'::jsonb)
  from public.staff_roles sr
  left join public.profiles p on p.id = sr.user_id
  left join auth.users u on u.id = sr.user_id;
$$;

grant execute on function public.tmp_list_staff() to authenticated, anon;
