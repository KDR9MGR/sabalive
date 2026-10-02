-- Personal-info filter for live chat and direct messages.
--
-- Phone numbers, e-mail addresses, UPI ids and messenger / social links are
-- replaced with *** before the message is stored, so no other user ever sees
-- them — the Realtime row every screen receives is already masked. The ORIGINAL
-- text, who sent it, and (for live chat) which host's room it was in are written
-- to personal_info_flags, which only platform admins can read; the Master panel
-- lists them there.
--
-- The patterns are mirrored in the app (lib/core/utils/personal_info_filter.dart)
-- so a sender's own optimistic bubble matches what the server stores. Keep the
-- two in step. They deliberately avoid \b / \y (those differ between the two
-- regex engines) and use only constructs both understand.

create or replace function public.mask_personal_info(p_text text, out masked text, out kinds text[])
language plpgsql immutable
as $$
declare
  t text := coalesce(p_text, '');
  -- name@domain.tld, plus the "(at)" / "[dot]" spellings
  email_re constant text :=
    '[A-Za-z0-9._%+\-]+[\s]*(?:@|\(at\)|\[at\])[\s]*[A-Za-z0-9\-]+(?:[\s]*(?:\.|\(dot\)|\[dot\])[\s]*[A-Za-z0-9\-]+)+';
  -- "john at gmail dot com"
  spoken_email_re constant text :=
    '[A-Za-z0-9._\-]+[\s]+at[\s]+(?:gmail|yahoo|hotmail|outlook|icloud|proton|rediff)[\s]*(?:\.|[\s]dot[\s])[\s]*[A-Za-z]{2,}';
  upi_re constant text :=
    '[A-Za-z0-9._\-]{2,}@(?:ok[a-z]+|ybl|ibl|axl|paytm|upi|apl|fbl|sbi|hdfcbank|icici|axisbank)';
  link_re constant text :=
    '(?:https?://)?(?:www\.)?(?:wa\.me|t\.me|telegram\.(?:me|org)|instagram\.com|snapchat\.com|facebook\.com|fb\.com|fb\.me|m\.me|linkedin\.com|twitter\.com|x\.com|discord\.gg|chat\.whatsapp\.com)/[^\s]*';
  -- 9+ digits, allowing spaces / dots / dashes / brackets (and emoji keycaps)
  -- between them: 98765 43210, +91-98765-43210, (022) 2345 6789. Nine, not
  -- eight, so an ordinary date like 2026-10-02 is left alone.
  phone_re constant text :=
    '\+?[0-9](?:[\s().\-\uFE0F\u20E3]{0,2}[0-9]){8,}[\uFE0F\u20E3]*';
  -- "nine eight seven six five four three two one zero"
  spoken_phone_re constant text :=
    '(?:(?:zero|one|two|three|four|five|six|seven|eight|nine|ek|do|teen|char|paanch|panch|chhe|chhah|saat|aath|nau)[\s,.\-]*){7,}';
begin
  kinds := '{}';
  if t ~* email_re or t ~* spoken_email_re then
    kinds := array_append(kinds, 'email');
    t := regexp_replace(t, email_re, '***', 'gi');
    t := regexp_replace(t, spoken_email_re, '***', 'gi');
  end if;
  if t ~* upi_re then
    kinds := array_append(kinds, 'upi');
    t := regexp_replace(t, upi_re, '***', 'gi');
  end if;
  if t ~* link_re then
    kinds := array_append(kinds, 'link');
    t := regexp_replace(t, link_re, '***', 'gi');
  end if;
  if t ~* phone_re or t ~* spoken_phone_re then
    kinds := array_append(kinds, 'phone');
    t := regexp_replace(t, phone_re, '***', 'gi');
    t := regexp_replace(t, spoken_phone_re, '***', 'gi');
  end if;
  masked := t;
end;
$$;

create table public.personal_info_flags (
  id bigint generated always as identity primary key,
  source text not null check (source in ('live_chat', 'direct_message')),
  -- no FK: the flag is written before the message row it describes exists
  source_row_id bigint,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  live_stream_id uuid references public.live_streams (id) on delete set null,
  host_id uuid references public.profiles (id) on delete set null,
  conversation_id uuid references public.conversations (id) on delete set null,
  -- the other person in a 1:1 DM (null for group chats and live chat)
  recipient_id uuid references public.profiles (id) on delete set null,
  original_text text not null,
  masked_text text not null,
  kinds text[] not null,
  status text not null default 'new' check (status in ('new', 'reviewed', 'actioned')),
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create index personal_info_flags_created_idx on public.personal_info_flags (created_at desc);
create index personal_info_flags_sender_idx on public.personal_info_flags (sender_id);
create index personal_info_flags_status_idx on public.personal_info_flags (status, created_at desc);

alter table public.personal_info_flags enable row level security;

create policy "Admins read personal info flags"
  on public.personal_info_flags for select using (public.is_admin_or_above());
create policy "Admins review personal info flags"
  on public.personal_info_flags for update
  using (public.is_admin_or_above()) with check (public.is_admin_or_above());
-- no insert/delete policy: only the triggers below (security definer) write rows

create or replace function public.filter_live_chat_personal_info()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  r record;
begin
  -- gift / system rows are written by server functions, not typed by a user
  if new.kind <> 'text' then
    return new;
  end if;

  select * into r from public.mask_personal_info(new.body);
  if array_length(r.kinds, 1) is null then
    return new;
  end if;

  insert into public.personal_info_flags
    (source, source_row_id, sender_id, live_stream_id, host_id, original_text, masked_text, kinds)
  values (
    'live_chat', new.id, new.sender_id, new.live_stream_id,
    (select host_id from public.live_streams where id = new.live_stream_id),
    new.body, r.masked, r.kinds
  );
  new.body := r.masked;
  return new;
end;
$$;

create or replace function public.filter_dm_personal_info()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  v_recipient uuid;
begin
  if new.kind <> 'text' or new.body is null then
    return new;
  end if;

  select * into r from public.mask_personal_info(new.body);
  if array_length(r.kinds, 1) is null then
    return new;
  end if;

  select cp.profile_id into v_recipient
    from public.conversation_participants cp
    join public.conversations c on c.id = cp.conversation_id
   where cp.conversation_id = new.conversation_id
     and not c.is_group
     and cp.profile_id <> new.sender_id
   limit 1;

  insert into public.personal_info_flags
    (source, source_row_id, sender_id, conversation_id, recipient_id, original_text, masked_text, kinds)
  values ('direct_message', new.id, new.sender_id, new.conversation_id, v_recipient, new.body, r.masked, r.kinds);
  new.body := r.masked;
  return new;
end;
$$;

revoke execute on function public.filter_live_chat_personal_info() from public;
revoke execute on function public.filter_dm_personal_info() from public;

create trigger live_chat_personal_info_filter
  before insert or update of body on public.live_chat_messages
  for each row execute function public.filter_live_chat_personal_info();

create trigger dm_personal_info_filter
  before insert or update of body on public.dm_messages
  for each row execute function public.filter_dm_personal_info();
