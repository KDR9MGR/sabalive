-- Down script for supabase/migrations/20261009090000_push_function_url_from_vault.sql
-- Applied BY HAND only. Puts push_notification() back to the definition from
-- 20260929100000_push_notifications.sql (production address typed in, no Vault lookup of the URL).
-- Nothing else changed in that migration, so there is nothing else to undo.
begin;
set local lock_timeout = '5s';

create or replace function public.push_notification()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_internal_secret';
  perform net.http_post(
    url := 'https://sfehzhtqtpuobnrvzvzp.supabase.co/functions/v1/send-push',
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

commit;
