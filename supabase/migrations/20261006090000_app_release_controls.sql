-- Release controls: the way to tell an old, broken app build to update, and to switch a feature off
-- without a new release. ADDITIVE ONLY: new columns with safe defaults on the existing app_config
-- singleton (0 = no minimum). App builds already in the field never read them.
--
--   min_android_version_code / min_ios_build : an app build below this shows "Update required".
--                                              0 means no minimum (today's behaviour).
--   latest_*                                 : the newest build actually released. A minimum above it is
--                                              refused, so a typo cannot lock everybody out.
--   update_message / *_store_url             : what the update screen says and where its button goes.
--   feature_flags (already existed, unused)  : server-side switches, {"key": true|false}. Keys the app reads:
--                                              animated_frames, speaking_waves. An absent key keeps the default (on).
alter table public.app_config
  add column if not exists min_android_version_code integer not null default 0,
  add column if not exists latest_android_version_code integer not null default 0,
  add column if not exists min_ios_build integer not null default 0,
  add column if not exists latest_ios_build integer not null default 0,
  add column if not exists update_message text not null default '',
  add column if not exists android_store_url text not null default 'https://play.google.com/store/apps/details?id=com.sabalive.in',
  add column if not exists ios_store_url text not null default '';

alter table public.app_config drop constraint if exists app_config_min_version_check;
alter table public.app_config add constraint app_config_min_version_check check (
  min_android_version_code >= 0 and min_ios_build >= 0
  and latest_android_version_code >= 0 and latest_ios_build >= 0
  and (latest_android_version_code = 0 or min_android_version_code <= latest_android_version_code)
  and (latest_ios_build = 0 or min_ios_build <= latest_ios_build)
);

comment on column public.app_config.feature_flags is
  'Server-side switches {"key": true|false}, read by the app. Known keys: animated_frames, speaking_waves. Absent = on.';

-- app_config is editable by every Master; these fields can lock users out of the app, so only a Super Admin
-- may change them. (The database owner, i.e. migrations and the SQL editor, is let through: auth.uid() is null.)
create or replace function public.guard_app_config_release_fields()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if (new.min_android_version_code, new.latest_android_version_code, new.min_ios_build, new.latest_ios_build,
      new.update_message, new.android_store_url, new.ios_store_url, new.feature_flags)
     is distinct from
     (old.min_android_version_code, old.latest_android_version_code, old.min_ios_build, old.latest_ios_build,
      old.update_message, old.android_store_url, old.ios_store_url, old.feature_flags)
  then
    if auth.uid() is not null and public.current_staff_role() is distinct from 'super_admin' then
      raise exception 'Only the Super Admin can change the app release controls' using errcode = '42501';
    end if;
    insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'app_release.changed',
            format('min android %s / ios %s; latest android %s / ios %s; flags %s',
                   new.min_android_version_code, new.min_ios_build,
                   new.latest_android_version_code, new.latest_ios_build, new.feature_flags::text),
            'warning');
  end if;
  return new;
end;
$$;

drop trigger if exists app_config_release_guard on public.app_config;
create trigger app_config_release_guard before update on public.app_config
  for each row execute function public.guard_app_config_release_fields();
