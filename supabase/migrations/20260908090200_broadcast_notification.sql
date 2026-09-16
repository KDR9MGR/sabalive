-- Admin broadcast: fan one message out to a notifications row per targeted
-- profile. notifications has no INSERT policy for clients (rows come from
-- triggers or service_role), so a SECURITY DEFINER function is the only way
-- the sabaliveadmin panel can create them. Audience values match the
-- panel's announcement audiences.

create function public.broadcast_notification(p_kind text, p_body text, p_audience text)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_count integer;
begin
  if not public.is_admin_or_above() then
    raise exception 'Only admins can broadcast notifications';
  end if;
  if coalesce(trim(p_body), '') = '' then
    raise exception 'Notification body is required';
  end if;
  if p_audience not in ('all', 'hosts', 'agencies', 'sub_admins') then
    raise exception 'Unknown audience %', p_audience;
  end if;

  with targets as (
    select p.id
    from public.profiles p
    where p_audience = 'all'
       or (p_audience = 'hosts' and p.is_host)
       or (p_audience = 'agencies' and exists (
             select 1 from public.staff_roles sr
             where sr.user_id = p.id and sr.role = 'agency_manager'))
       or (p_audience = 'sub_admins' and exists (
             select 1 from public.staff_roles sr
             where sr.user_id = p.id and sr.role = 'sub_admin'))
  ), ins as (
    insert into public.notifications (profile_id, kind, body)
    select id, coalesce(nullif(trim(p_kind), ''), 'announcement'), p_body from targets
    returning 1
  )
  select count(*) into v_count from ins;

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'notification.broadcast', p_audience || ' x' || v_count, 'info');

  return v_count;
end;
$$;

revoke execute on function public.broadcast_notification(text, text, text) from anon;
