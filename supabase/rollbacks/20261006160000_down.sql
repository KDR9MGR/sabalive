-- Down script for supabase/migrations/20261006160000_live_monitor_master_needs_grant.sql
-- Applied BY HAND only. Puts the old default back: a Master may use Live Monitor unless switched off.
begin;
set local lock_timeout = '5s';
create or replace function public.staff_can_ghost_watch()
returns boolean
language sql stable security definer set search_path = public
as $$
  select case public.current_staff_role()
    when 'super_admin' then true
    when 'admin' then coalesce(
      nullif((select s.permissions ->> 'monitor_lives' from public.staff_roles s where s.user_id = auth.uid()), '')::boolean,
      true)
    else false
  end;
$$;
commit;
