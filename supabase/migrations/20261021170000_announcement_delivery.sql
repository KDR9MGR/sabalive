-- Announcements that actually arrive: send now or at a chosen time (Content / Settings -> Announcements).
--
-- WHY THEY NEVER ARRIVED. "Broadcast to users" (broadcast_notification) wrote one notifications row per user in ONE statement, and every row fires the
-- push bridge (a vault read plus an HTTP call). For everyone that is ~690 rows, and the signed-in API role has an 8 second statement timeout, so the
-- statement was cancelled and rolled back whole: no rows, no audit entry (production: three announcements, all hand-marked "sent", zero notification
-- rows). "Schedule" only changed a word in a column: nothing ever looked at it. The title was dropped too (only the message was sent), and the
-- Channel setting was ignored.
--
-- WHAT THIS DOES
--   * announcements gets send_at (when), recipients (how many got it) and last_error; status gains 'sending'.
--   * deliver_announcement(id, batch) writes the notifications for the next batch of the audience (ghost accounts excluded, nobody twice: a unique
--     index on notifications(announcement_id, profile_id)); when nobody is left the announcement becomes 'sent' with its recipient count.
--   * process_announcements() runs every minute (pg_cron, which has no 8 second limit) and delivers 300 users per announcement per minute, so
--     690 users take about 3 minutes and 50,000 would take the same way, never one huge statement. Scheduled ones start when send_at arrives.
--   * announcement_send_now(id): queues it and delivers the first 150 users right away (inside the API timeout); the cron does the rest.
--     announcement_schedule(id, time): a future time. announcement_cancel(id): a scheduled one goes back to draft. Master / Super Admin with the
--     "Content / settings" switch only (as broadcasting always was); every send is audit-logged.
--   * The notification text is "Title" + new line + "Message", so the title shows in the list and in the push (the push function only knows the body).
--   * Channel 'in_app' = the notifications list only, NO push: push_notification() skips rows written while app.skip_push is on.
--   * The old broadcast_notification() stays as it was (nothing calls it any more).
-- ALSO (hardening, unrelated to announcements): grant_lucky_box_rewards() was callable by anyone with the public API key. Only the cron job runs it.
-- Additive except the two changed bodies (push_notification: one guard added; grant_lucky_box_rewards: privileges only). Rollback:
-- supabase/rollbacks/20261021170000_down.sql.
set local lock_timeout = '5s';

-- 1. announcements: when, and how it went
alter table public.announcements
  add column if not exists send_at timestamptz,
  add column if not exists recipients integer,
  add column if not exists last_error text;
alter table public.announcements drop constraint if exists announcements_status_check;
alter table public.announcements add constraint announcements_status_check check (status in ('draft', 'scheduled', 'sending', 'sent'));

-- 2. which announcement a notification came from (also what stops a user getting one twice)
alter table public.notifications
  add column if not exists announcement_id uuid references public.announcements (id) on delete set null;
create unique index if not exists notifications_announcement_profile_uidx
  on public.notifications (announcement_id, profile_id) where announcement_id is not null;

-- 3. the push bridge: skip the push for rows written while app.skip_push is on (in-app-only announcements). Otherwise exactly as before.
create or replace function public.push_notification()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_secret text;
  v_base text;
begin
  if current_setting('app.skip_push', true) = 'on' then
    return new;
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_internal_secret';
  select decrypted_secret into v_base from vault.decrypted_secrets where name = 'functions_base_url';
  perform net.http_post(
    url := coalesce(nullif(rtrim(trim(v_base), '/'), ''), 'https://sfehzhtqtpuobnrvzvzp.supabase.co')
           || '/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Internal-Secret', v_secret),
    body := jsonb_build_object(
      'profile_id', new.profile_id,
      'kind', new.kind,
      'body', new.body,
      'notification_id', new.id
    )
  );
  return new;
end;
$$;

-- 4. deliver one batch of one announcement. Returns how many users got it in this batch. Internal: only the cron job and the staff RPCs below call it.
create or replace function public.deliver_announcement(p_id uuid, p_limit integer default 300)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  a public.announcements;
  v_n integer := 0;
  v_body text;
  v_limit integer := least(greatest(coalesce(p_limit, 300), 1), 1000);
begin
  select * into a from public.announcements where id = p_id and status in ('scheduled', 'sending') for update;
  if a.id is null then return 0; end if;
  if a.status = 'scheduled' then
    update public.announcements set status = 'sending' where id = a.id;
  end if;
  v_body := case
    when btrim(coalesce(a.title, '')) <> '' and btrim(coalesce(a.body, '')) <> '' then btrim(a.title) || E'\n' || btrim(a.body)
    else coalesce(nullif(btrim(a.body), ''), btrim(a.title))
  end;
  if a.channel = 'in_app' then perform set_config('app.skip_push', 'on', true); end if;

  with targets as (
    select p.id
      from public.profiles p
     where not coalesce(p.is_ghost, false)
       and (a.audience = 'all'
            or (a.audience = 'hosts' and p.is_host)
            or (a.audience = 'agencies' and exists (select 1 from public.staff_roles sr where sr.user_id = p.id and sr.role = 'agency_manager'))
            or (a.audience = 'sub_admins' and exists (select 1 from public.staff_roles sr where sr.user_id = p.id and sr.role = 'sub_admin')))
       and not exists (select 1 from public.notifications n where n.announcement_id = a.id and n.profile_id = p.id)
     order by p.id
     limit v_limit
  ), ins as (
    insert into public.notifications (profile_id, kind, body, announcement_id)
    select id, 'announcement', v_body, a.id from targets
    returning 1
  )
  select count(*) into v_n from ins;
  perform set_config('app.skip_push', 'off', true);

  -- a short batch means nobody is left: done
  if v_n < v_limit then
    update public.announcements
       set status = 'sent', sent_at = now(), last_error = null,
           recipients = (select count(*) from public.notifications n where n.announcement_id = a.id)
     where id = a.id;
  end if;
  return v_n;
end;
$$;

-- 5. the cron job: scheduled ones whose time has come, and ones still being delivered
create or replace function public.process_announcements()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r record;
begin
  for r in
    select id from public.announcements
     where status in ('scheduled', 'sending') and coalesce(send_at, created_at) <= now()
     order by coalesce(send_at, created_at)
     limit 5
  loop
    begin
      perform public.deliver_announcement(r.id, 300);
    exception when others then
      update public.announcements set last_error = left(sqlerrm, 300) where id = r.id;
    end;
  end loop;
end;
$$;

do $outer$
begin
  if not exists (select 1 from cron.job where jobname = 'process-announcements') then
    perform cron.schedule('process-announcements', '* * * * *', $sql$select public.process_announcements()$sql$);
  end if;
end;
$outer$;

-- 6. what the panel calls
create or replace function public.announcement_send_now(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  a public.announcements;
  v_n integer;
begin
  if not (public.is_admin_or_above() and public.staff_cap_on('manage_content')) then
    raise exception 'Only a Master or Super Admin with the Content / settings switch can send an announcement';
  end if;
  select * into a from public.announcements where id = p_id for update;
  if a.id is null then raise exception 'Announcement not found'; end if;
  if a.status in ('sending', 'sent') then raise exception 'This announcement was already sent'; end if;
  if btrim(coalesce(a.body, '')) = '' then raise exception 'Write the message first'; end if;

  update public.announcements set status = 'scheduled', send_at = now(), last_error = null where id = p_id;
  v_n := public.deliver_announcement(p_id, 150);   -- the first 150 right now; the cron job delivers the rest within a few minutes

  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'announcement.send', p_id::text || ' ' || left(a.title, 80) || ' (' || a.audience || ', ' || a.channel || ')', 'warning');
  return jsonb_build_object('delivered_now', v_n, 'status', (select status from public.announcements where id = p_id));
end;
$$;

create or replace function public.announcement_schedule(p_id uuid, p_send_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  a public.announcements;
begin
  if not (public.is_admin_or_above() and public.staff_cap_on('manage_content')) then
    raise exception 'Only a Master or Super Admin with the Content / settings switch can schedule an announcement';
  end if;
  if p_send_at is null or p_send_at < now() + interval '30 seconds' then
    raise exception 'Pick a time in the future';
  end if;
  select * into a from public.announcements where id = p_id for update;
  if a.id is null then raise exception 'Announcement not found'; end if;
  if a.status in ('sending', 'sent') then raise exception 'This announcement was already sent'; end if;
  if btrim(coalesce(a.body, '')) = '' then raise exception 'Write the message first'; end if;

  update public.announcements set status = 'scheduled', send_at = p_send_at, last_error = null where id = p_id;
  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'announcement.schedule', p_id::text || ' ' || left(a.title, 80) || ' at ' || p_send_at::text, 'info');
  return jsonb_build_object('status', 'scheduled', 'send_at', p_send_at);
end;
$$;

create or replace function public.announcement_cancel(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  a public.announcements;
begin
  if not (public.is_admin_or_above() and public.staff_cap_on('manage_content')) then
    raise exception 'Only a Master or Super Admin with the Content / settings switch can cancel a scheduled announcement';
  end if;
  select * into a from public.announcements where id = p_id for update;
  if a.id is null then raise exception 'Announcement not found'; end if;
  if a.status <> 'scheduled' then raise exception 'Only a scheduled announcement can be cancelled'; end if;
  update public.announcements set status = 'draft', send_at = null where id = p_id;
  insert into public.audit_logs (actor_id, action, target, severity)
    values (auth.uid(), 'announcement.cancel', p_id::text || ' ' || left(a.title, 80), 'info');
  return jsonb_build_object('status', 'draft');
end;
$$;

revoke execute on function public.deliver_announcement(uuid, integer) from public, anon, authenticated;
revoke execute on function public.process_announcements() from public, anon, authenticated;
revoke execute on function public.announcement_send_now(uuid) from public, anon;
revoke execute on function public.announcement_schedule(uuid, timestamptz) from public, anon;
revoke execute on function public.announcement_cancel(uuid) from public, anon;
grant execute on function public.announcement_send_now(uuid) to authenticated;
grant execute on function public.announcement_schedule(uuid, timestamptz) to authenticated;
grant execute on function public.announcement_cancel(uuid) to authenticated;

-- 7. hardening: only the cron job runs the Lucky Box payout (the apps never call it)
revoke execute on function public.grant_lucky_box_rewards() from public, anon, authenticated;
