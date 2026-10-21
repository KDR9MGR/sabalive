-- Down script for supabase/migrations/20261021170000_announcement_delivery.sql
-- Applied BY HAND only. Stops the delivery job, removes the announcement functions, puts push_notification() back exactly as it was (no skip guard),
-- removes notifications.announcement_id and its index, takes announcements back to its three statuses and three columns, and gives
-- grant_lucky_box_rewards() back the privileges it had before (anon and authenticated; only the cron job needs it).
-- Cannot be undone by this script: announcements already delivered keep their notification rows (they just lose the link to the announcement), and
-- an announcement that was 'sending' is set to 'sent'.
begin;
set local lock_timeout = '5s';

do $outer$
begin
  if exists (select 1 from cron.job where jobname = 'process-announcements') then
    perform cron.unschedule('process-announcements');
  end if;
end;
$outer$;

drop function if exists public.announcement_cancel(uuid);
drop function if exists public.announcement_schedule(uuid, timestamptz);
drop function if exists public.announcement_send_now(uuid);
drop function if exists public.process_announcements();
drop function if exists public.deliver_announcement(uuid, integer);

create or replace function public.push_notification()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_secret text;
  v_base text;
begin
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

drop index if exists public.notifications_announcement_profile_uidx;
alter table public.notifications drop column if exists announcement_id;

update public.announcements set status = 'sent' where status = 'sending';
alter table public.announcements drop constraint if exists announcements_status_check;
alter table public.announcements add constraint announcements_status_check check (status in ('draft', 'scheduled', 'sent'));
alter table public.announcements
  drop column if exists send_at,
  drop column if exists recipients,
  drop column if exists last_error;

grant execute on function public.grant_lucky_box_rewards() to anon, authenticated;
commit;
