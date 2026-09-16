-- TEMP diagnostic: dump the live RLS policies for the messaging tables.
create function public.dm_debug_policies()
returns jsonb language sql stable security definer set search_path = public, pg_catalog
as $$
  select jsonb_agg(jsonb_build_object(
    'table', tablename,
    'policy', policyname,
    'cmd', cmd,
    'permissive', permissive,
    'roles', roles,
    'qual', qual,
    'with_check', with_check
  ) order by tablename, policyname)
  from pg_policies
  where schemaname = 'public'
    and tablename in ('conversations', 'conversation_participants', 'dm_messages');
$$;

grant execute on function public.dm_debug_policies() to authenticated, anon;
