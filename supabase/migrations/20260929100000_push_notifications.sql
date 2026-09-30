-- Push notifications (FCM). Device tokens are registered by the client via
-- register_device_token/unregister_device_token (see
-- lib/services/push_notifications_service.dart). Everything else follows
-- the notifications table's existing pattern (see follows_notify in
-- 20260905090400_gamification_content.sql): a trigger inserts a row into
-- public.notifications, and ONE generic bridge trigger on notifications
-- itself fans out to the send-push Edge Function for every row inserted
-- there, regardless of which trigger (or future one) wrote it — so a new
-- notification kind only needs to insert into notifications to also get a
-- push automatically, no new push-specific wiring required.

create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------- device tokens
create table public.device_tokens (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  token text not null,
  platform text not null check (platform in ('android', 'ios')),
  updated_at timestamptz not null default now(),
  primary key (profile_id, token)
);

alter table public.device_tokens enable row level security;

create policy "Users manage their own device tokens"
  on public.device_tokens for all
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

create function public.register_device_token(p_token text, p_platform text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_platform not in ('android', 'ios') then
    raise exception 'p_platform must be android or ios';
  end if;
  insert into public.device_tokens (profile_id, token, platform, updated_at)
  values (auth.uid(), p_token, p_platform, now())
  on conflict (profile_id, token) do update
    set platform = excluded.platform, updated_at = now();
end;
$$;

create function public.unregister_device_token(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.device_tokens where profile_id = auth.uid() and token = p_token;
end;
$$;

-- -------------------------------------------------------- live-started notify
create function public.notify_followers_live()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'live' then
    insert into public.notifications (profile_id, kind, body)
    select f.follower_id, 'live',
      (select name from public.profiles where id = new.host_id) || ' just went live: ' || new.title
    from public.follows f
    where f.followee_id = new.host_id;
  end if;
  return new;
end;
$$;

create trigger live_streams_notify_followers
  after insert on public.live_streams
  for each row execute function public.notify_followers_live();

-- -------------------------------------------------------------- DM notify
-- Only 1:1/group text messages — live in-room chat (live_chat_messages) is
-- a different table and deliberately NOT wired here, nobody wants a push
-- for every line of chat in a room they're already watching.
create function public.notify_dm_message()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'text' then
    insert into public.notifications (profile_id, kind, body)
    select cp.profile_id, 'message',
      (select name from public.profiles where id = new.sender_id) || ': ' ||
        left(coalesce(new.body, ''), 120)
    from public.conversation_participants cp
    where cp.conversation_id = new.conversation_id
      and cp.profile_id <> new.sender_id
      and cp.status = 'accepted';
  end if;
  return new;
end;
$$;

create trigger dm_messages_notify
  after insert on public.dm_messages
  for each row execute function public.notify_dm_message();

-- ------------------------------------------------------------- coins notify
-- Covers every wallet_ledger kind except gift_sent (the sender already sees
-- their own send happen live in the gift sheet — no need to also push them).
create function public.notify_wallet_ledger_entry()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_body text;
begin
  v_body := case new.kind
    when 'gift_received' then 'You received a gift — +' || new.amount || ' ' || new.currency
    when 'purchase' then 'Purchase successful — +' || new.amount || ' ' || new.currency
    when 'grant' then 'You received ' || new.amount || ' ' || new.currency
    when 'withdrawal' then 'Withdrawal of ' || abs(new.amount) || ' ' || new.currency || ' processed'
    else null
  end;
  if v_body is not null then
    insert into public.notifications (profile_id, kind, body)
    values (new.profile_id, 'coins_' || new.kind, v_body);
  end if;
  return new;
end;
$$;

create trigger wallet_ledger_notify
  after insert on public.wallet_ledger
  for each row execute function public.notify_wallet_ledger_entry();

-- ------------------------------------------------------------- push bridge
-- Fires for EVERY notification row, including the pre-existing
-- follows_notify (new-follower) trigger — that one push comes "free" here
-- as a natural consequence of this being a generic bridge, not something
-- separately wired. Fire-and-forget via pg_net so a slow/unreachable Edge
-- Function never blocks or fails the write that triggered it. The internal
-- secret is generated once below and stored in Vault (never sent to the
-- client) — it just proves to the Edge Function that the call really came
-- from this project's own database, since the function is deployed with
-- verify_jwt disabled (it isn't a user-facing endpoint).
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'push_internal_secret')
where not exists (select 1 from vault.secrets where name = 'push_internal_secret');

create function public.push_notification()
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

create trigger notifications_push
  after insert on public.notifications
  for each row execute function public.push_notification();
