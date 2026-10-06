-- Live Monitor (invisible ghost watching) is now OFF by default for a Master: a Master can watch only after a
-- Super Admin has switched "Live monitor" on for that account (staff_roles.permissions.monitor_lives = true).
-- Before this, a Master had it unless it was explicitly switched off. A Super Admin always has it; every other
-- role never does. The only change is the default for 'admin': true -> false.
create or replace function public.staff_can_ghost_watch()
returns boolean
language sql stable security definer set search_path = public
as $$
  select case public.current_staff_role()
    when 'super_admin' then true
    when 'admin' then coalesce(
      nullif((select s.permissions ->> 'monitor_lives' from public.staff_roles s where s.user_id = auth.uid()), '')::boolean,
      false)
    else false
  end;
$$;
