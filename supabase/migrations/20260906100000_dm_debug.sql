-- TEMP diagnostic: echoes what the DB sees for the calling request so we can
-- confirm auth.uid()/role on PostgREST writes. Drop in a follow-up migration.
create function public.dm_debug()
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'auth_uid', auth.uid(),
    'auth_role', auth.role(),
    'current_user', current_user,
    'jwt_claims', current_setting('request.jwt.claims', true)
  );
$$;

grant execute on function public.dm_debug() to authenticated, anon;
