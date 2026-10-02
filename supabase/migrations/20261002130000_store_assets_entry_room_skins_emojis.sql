-- Store artwork + admin management, entry effects seen by the whole room, room
-- skins, and a panel-managed emoji / GIF catalog for live chat.
--
-- Until now store_items had only an emoji stand-in and no way to change it
-- except by hand in SQL, entry effects were bought and equipped but never shown
-- to anyone, and the live-chat quick-emoji list was hard-coded in the app.

-- ---------------------------------------------------------------------------
-- 1. Store items: uploaded artwork (SVGA / MP4 / WebP / GIF / PNG), a Room Skin
--    category, and admin write access.
-- ---------------------------------------------------------------------------
alter table public.store_items add column if not exists asset_url text;

alter table public.store_items drop constraint store_items_category_check;
alter table public.store_items add constraint store_items_category_check
  check (category in ('frame', 'vip', 'entry_effect', 'vehicle', 'room_skin'));

create policy "Admins insert store items" on public.store_items
  for insert with check (public.is_admin_or_above());
create policy "Admins update store items" on public.store_items
  for update using (public.is_admin_or_above()) with check (public.is_admin_or_above());
create policy "Admins delete store items" on public.store_items
  for delete using (public.is_admin_or_above());

insert into public.store_items (category, name, emoji, price_coins, duration_days, sort_order) values
  ('room_skin', 'Starry Night', '🌌', 4000, 30, 1),
  ('room_skin', 'Sunset Lounge', '🌅', 6000, 30, 2);

-- GIF and JPEG joined SVGA / MP4 / WebP / PNG as accepted uploads.
update storage.buckets
   set allowed_mime_types = array['image/png', 'image/webp', 'image/gif', 'image/jpeg', 'video/mp4', 'application/octet-stream']
 where id in ('gift-assets', 'banners');

-- ---------------------------------------------------------------------------
-- 2. Entry effects: the join row carries the joiner's equipped entry effect /
--    vehicle so every screen in the room can play it (vehicle first).
-- ---------------------------------------------------------------------------
alter table public.live_chat_messages add column if not exists entry_item_ids uuid[];

create or replace function public.join_live_stream(p_stream_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_entry uuid[];
begin
  if auth.uid() is null then
    raise exception 'Must be signed in to join a live stream';
  end if;
  update public.live_stream_viewers
  set left_at = now()
  where live_stream_id = p_stream_id and viewer_id = auth.uid() and left_at is null;
  insert into public.live_stream_viewers (live_stream_id, viewer_id)
  values (p_stream_id, auth.uid());

  select array_agg(ui.item_id order by case si.category when 'vehicle' then 0 else 1 end)
    into v_entry
    from public.user_items ui
    join public.store_items si on si.id = ui.item_id
   where ui.profile_id = auth.uid()
     and ui.equipped
     and ui.expires_at > now()
     and si.status = 'active'
     and si.category in ('entry_effect', 'vehicle');

  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, entry_item_ids)
  values (p_stream_id, auth.uid(), 'joined the live stream', 'system', v_entry);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Room skins: a host's equipped skin is the background of every room they
--    host. It is copied onto live_streams (a row every room screen already
--    watches) when the stream starts and whenever they equip / unequip one.
-- ---------------------------------------------------------------------------
alter table public.live_streams
  add column if not exists room_skin_item_id uuid references public.store_items (id) on delete set null;

create or replace function public.equipped_room_skin(p_host uuid)
returns uuid
language sql stable security definer set search_path = public
as $$
  select ui.item_id
    from public.user_items ui
    join public.store_items si on si.id = ui.item_id
   where ui.profile_id = p_host
     and ui.equipped
     and ui.expires_at > now()
     and si.status = 'active'
     and si.category = 'room_skin'
   limit 1;
$$;
revoke execute on function public.equipped_room_skin(uuid) from public;

create or replace function public.live_stream_default_room_skin()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.room_skin_item_id is null then
    new.room_skin_item_id := public.equipped_room_skin(new.host_id);
  end if;
  return new;
end;
$$;
revoke execute on function public.live_stream_default_room_skin() from public;

create trigger live_streams_default_room_skin
  before insert on public.live_streams
  for each row execute function public.live_stream_default_room_skin();

create or replace function public.sync_room_skin_to_live_streams()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from public.store_items where id = new.item_id and category = 'room_skin') then
    update public.live_streams
       set room_skin_item_id = public.equipped_room_skin(new.profile_id)
     where host_id = new.profile_id and status = 'live';
  end if;
  return null;
end;
$$;
revoke execute on function public.sync_room_skin_to_live_streams() from public;

create trigger user_items_sync_room_skin
  after insert or update of equipped on public.user_items
  for each row execute function public.sync_room_skin_to_live_streams();

-- ---------------------------------------------------------------------------
-- 4. Live-chat emoji / GIF catalog, managed from the admin panel.
-- ---------------------------------------------------------------------------
create table public.live_emojis (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('emoji', 'gif')),
  label text not null,
  emoji text,
  asset_url text,
  sort_order integer not null default 0,
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  check ((kind = 'emoji' and emoji is not null) or (kind = 'gif' and asset_url is not null))
);

alter table public.live_emojis enable row level security;

create policy "Active live emojis are public" on public.live_emojis
  for select using (status = 'active' or public.is_admin_or_above());
create policy "Admins insert live emojis" on public.live_emojis
  for insert with check (public.is_admin_or_above());
create policy "Admins update live emojis" on public.live_emojis
  for update using (public.is_admin_or_above()) with check (public.is_admin_or_above());
create policy "Admins delete live emojis" on public.live_emojis
  for delete using (public.is_admin_or_above());

insert into public.live_emojis (kind, label, emoji, sort_order) values
  ('emoji', 'Heart', '❤️', 1), ('emoji', 'Fire', '🔥', 2), ('emoji', 'Clap', '👏', 3),
  ('emoji', 'Laugh', '😂', 4), ('emoji', 'Wow', '😮', 5), ('emoji', 'Party', '🎉', 6),
  ('emoji', 'Love', '😍', 7), ('emoji', 'Cool', '😎', 8), ('emoji', 'Hundred', '💯', 9),
  ('emoji', 'Pray', '🙏', 10);

-- A GIF / animated sticker in chat is its own message kind, written only by this
-- function so the url always comes from the catalog (users can't point a chat row
-- at an arbitrary address).
alter table public.live_chat_messages add column if not exists sticker_url text;
alter table public.live_chat_messages drop constraint live_chat_messages_kind_check;
alter table public.live_chat_messages add constraint live_chat_messages_kind_check
  check (kind in ('text', 'gift', 'system', 'sticker'));

create or replace function public.send_live_gif(p_stream_id uuid, p_emoji_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_item public.live_emojis%rowtype;
begin
  if v_me is null then
    raise exception 'Must be signed in to chat';
  end if;
  select * into v_item from public.live_emojis where id = p_emoji_id and status = 'active' and kind = 'gif';
  if not found then
    raise exception 'That GIF is no longer available';
  end if;
  if not exists (select 1 from public.live_streams where id = p_stream_id and status = 'live') then
    raise exception 'This live stream has ended';
  end if;
  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, sticker_url)
  values (p_stream_id, v_me, v_item.label, 'sticker', v_item.asset_url);
end;
$$;
revoke execute on function public.send_live_gif(uuid, uuid) from public;
grant execute on function public.send_live_gif(uuid, uuid) to authenticated;
