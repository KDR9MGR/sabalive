-- The push bridge (public.push_notification, fired after every insert on notifications) posts to the
-- send-push Edge Function. Its address was typed into the function: the PRODUCTION project. A second
-- project (staging) built from these migrations would therefore call production on every notification.
--
-- Now the base address comes from a Vault secret named functions_base_url. WITHOUT that secret the
-- function behaves exactly as before (the production address), so production needs no change and keeps
-- working untouched. A staging project sets the secret to its own address right after its schema is
-- applied (scripts/staging/bootstrap.sh does it and checks it).
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
