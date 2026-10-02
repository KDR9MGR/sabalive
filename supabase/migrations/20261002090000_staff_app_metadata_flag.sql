-- Admin-panel (staff) accounts must never use the mobile app. They share the
-- same Supabase project and login endpoint as the app, so the server cannot
-- tell the two clients apart at sign-in; the app has to refuse them itself.
-- To make that refusal instant and impossible to fail open, mirror "is this a
-- staff account" into the account's own app_metadata (`is_staff: true`), which
-- the app reads straight off the session it just received — no extra query,
-- no network dependency.
--
-- app_metadata is the right home for this: it is server-controlled (a user
-- cannot edit their own, unlike user_metadata).

create function public.sync_staff_app_flag()
returns trigger
language plpgsql security definer set search_path = public, auth
as $$
begin
  if tg_op = 'DELETE' then
    update auth.users
       set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) - 'is_staff'
     where id = old.user_id;
    return old;
  end if;
  update auth.users
     set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"is_staff": true}'::jsonb
   where id = new.user_id;
  return new;
end;
$$;

revoke execute on function public.sync_staff_app_flag() from public, anon, authenticated;

create trigger staff_roles_sync_app_flag
  after insert or delete on public.staff_roles
  for each row execute function public.sync_staff_app_flag();

-- accounts that are already staff
update auth.users u
   set raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb) || '{"is_staff": true}'::jsonb
 where exists (select 1 from public.staff_roles s where s.user_id = u.id);
