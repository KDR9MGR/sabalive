-- Gift notices (owner, 2026-11-07: "both gift and game win strip should show in home and in room"; chosen: big gifts everywhere, from 5,000 coins).
--
-- A gift strip used to come only from the room where the gift was sent (the app read the gift's chat row). To show it on Home and in EVERY room, like the game wins
-- (20261107100000_game_win_notices), this is a platform-wide feed: whenever a gift SEND costs at least gift_notice_min_coins() coins (5,000), one row lands in gift_notices and
-- every signed-in phone hears about it over Realtime and draws the strip.
--
-- The cost is the whole send, the same rule the app used: gift price x quantity x people. A send is ONE live_chat_messages row of kind 'gift' (send_gift, send_gift_v2, send_gift_to_all
-- and v2 / v3 all write exactly one), so one trigger on that row covers every version of the gift functions (an old app's send included) without touching them. The trigger fires ONLY
-- for a gift row (WHEN ...), never for a chat line, and swallows every error: a notice problem must never stop a gift.
-- Additive: a new table, two new functions and a trigger. Old apps never read the table. The trigger is created with a short lock timeout (a busy table).
-- Rollback: supabase/rollbacks/20261107110000_down.sql.

create or replace function public.gift_notice_min_coins()
returns bigint language sql immutable
as $$ select 5000::bigint $$;

create table if not exists public.gift_notices (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles (id) on delete cascade,
  sender_name text not null,
  sender_avatar_url text,
  receiver_name text,
  receiver_avatar_url text,
  to_all boolean not null default false,
  gift_name text,
  gift_emoji text not null default '🎁',
  gift_icon_url text,
  quantity integer not null default 1 check (quantity > 0),
  coins bigint not null check (coins > 0),
  created_at timestamptz not null default now()
);
create index if not exists gift_notices_created_idx on public.gift_notices (created_at desc);
comment on table public.gift_notices is 'One row per gift send of at least gift_notice_min_coins() coins (price x quantity x people), written only by the trigger on live_chat_messages; every signed-in phone reads it over Realtime to draw the notification strip. Rows older than 2 days are removed by the next insert.';

alter table public.gift_notices enable row level security;
revoke all on public.gift_notices from public, anon, authenticated;
grant select on public.gift_notices to authenticated;
drop policy if exists "Signed-in users see big gifts" on public.gift_notices;
create policy "Signed-in users see big gifts" on public.gift_notices for select to authenticated using (true);

create or replace function public._gift_notice_after_chat()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_gift record;
  v_sender record;
  v_recv record;
  v_recv_id uuid;
  v_qty integer;
  v_people integer;
  v_cost bigint;
begin
  select name, emoji, price_coins, icon_url into v_gift from public.gifts where id = new.gift_id;
  if not found then
    return new;
  end if;
  v_qty := greatest(coalesce(new.gift_count, 1), 1);
  v_people := case when new.gift_receiver_ids is null then 1 else greatest(cardinality(new.gift_receiver_ids), 1) end;
  v_cost := v_gift.price_coins::bigint * v_qty * v_people;
  if v_cost < public.gift_notice_min_coins() then
    return new;
  end if;
  select name, avatar_url, coalesce(is_ghost, false) as ghost into v_sender from public.profiles where id = new.sender_id;
  if not found or v_sender.ghost then
    return new;
  end if;
  if not coalesce(new.to_all, false) then
    -- the receiver the row names; an older send does not name one: it was a gift to the room's host
    v_recv_id := case when new.gift_receiver_ids is not null and cardinality(new.gift_receiver_ids) > 0 then new.gift_receiver_ids[1]
                      else (select host_id from public.live_streams where id = new.live_stream_id) end;
    if v_recv_id is not null then
      select name, avatar_url into v_recv from public.profiles where id = v_recv_id;
    end if;
  end if;
  insert into public.gift_notices (sender_id, sender_name, sender_avatar_url, receiver_name, receiver_avatar_url, to_all, gift_name, gift_emoji, gift_icon_url, quantity, coins)
  values (new.sender_id, coalesce(nullif(btrim(v_sender.name), ''), 'Someone'), v_sender.avatar_url,
          case when coalesce(new.to_all, false) then null else nullif(btrim(v_recv.name), '') end,
          case when coalesce(new.to_all, false) then null else v_recv.avatar_url end,
          coalesce(new.to_all, false), v_gift.name, coalesce(nullif(v_gift.emoji, ''), '🎁'), nullif(btrim(v_gift.icon_url), ''), v_qty, v_cost);
  delete from public.gift_notices where created_at < now() - interval '2 days';
  return new;
exception when others then
  return new;   -- never let a notice problem touch a gift
end;
$$;
revoke execute on function public._gift_notice_after_chat() from public, anon, authenticated;

set local lock_timeout = '5s';
drop trigger if exists live_chat_messages_gift_notice on public.live_chat_messages;
create trigger live_chat_messages_gift_notice
  after insert on public.live_chat_messages
  for each row
  when (new.gift_id is not null)
  execute function public._gift_notice_after_chat();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'gift_notices') then
    alter publication supabase_realtime add table public.gift_notices;
  end if;
end $$;
