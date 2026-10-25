-- Gifts with a quantity, as ONE action, with a chat line that says what happened; and who the gift went to, so only they hear its sound.
--
-- Before: a gift of "x10" was ten separate send_gift calls, so ten chat lines and ten effects for the whole room, and "Send to All" ignored the quantity
-- (the sheet showed price x quantity but sent one each). Now:
--   send_gift_v2(gift, receiver, live, quantity)   charges price x quantity up front, writes the same ledger / gift rows send_gift writes (once per unit, so levels,
--                                                  diamonds and totals behave exactly the same), and posts ONE chat line: "sent <person> 10x Rose".
--   send_gift_to_all_v2(gift, live, quantity)      the same for everyone on a seat plus the host (never the sender): charges price x people x quantity up front, ONE
--                                                  chat line: "sent 10x Rose to 5 people" (the quantity is always written, "1x" too).
-- The chat row also records gift_count and gift_receiver_ids (the people the gift went to). The app uses them to play the gift's sound only on the receivers'
-- phones, and to play a combo once for the room.
--
-- Additive only: two columns that are null for every old row, and two functions with new names. send_gift and send_gift_to_all are untouched, so every installed
-- app keeps working; an app that does not know the new functions keeps calling the old ones. Rollback: supabase/rollbacks/20261025100000_down.sql.
alter table public.live_chat_messages
  add column if not exists gift_count integer,
  add column if not exists gift_receiver_ids uuid[];
alter table public.live_chat_messages drop constraint if exists live_chat_messages_gift_count_check;
-- NOT VALID: the check applies to new rows only and the busy chat table is not scanned (every old row is null, so it would pass anyway)
alter table public.live_chat_messages add constraint live_chat_messages_gift_count_check check (gift_count is null or gift_count between 1 and 99) not valid;

create or replace function public.send_gift_v2(
  p_gift_id uuid, p_receiver_id uuid, p_live_stream_id uuid default null, p_quantity integer default 1)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_qty integer := coalesce(p_quantity, 1);
  v_price integer;
  v_gift_name text;
  v_gift_emoji text;
  v_receiver_name text;
  v_i integer;
begin
  if v_sender is null then
    raise exception 'Must be signed in to send a gift';
  end if;
  if v_qty < 1 or v_qty > 99 then
    raise exception 'Pick a quantity from 1 to 99';
  end if;

  select price_coins, name, emoji into v_price, v_gift_name, v_gift_emoji
    from public.gifts where id = p_gift_id and status = 'active';
  if v_price is null then
    raise exception 'Unknown or inactive gift';
  end if;

  if coalesce((select coins from public.wallets where profile_id = v_sender), 0) < v_price::bigint * v_qty then
    raise exception 'Insufficient coins';
  end if;

  for v_i in 1..v_qty loop
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
      values (v_sender, 'gift_sent', 'coins', -v_price, 'gift_transactions', 'Gift sent');
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
      values (p_receiver_id, 'gift_received', 'diamonds', v_price, 'gift_transactions', 'Gift received');
    insert into public.gift_transactions (live_stream_id, sender_id, receiver_id, gift_id, coins)
      values (p_live_stream_id, v_sender, p_receiver_id, p_gift_id, v_price);
  end loop;

  if p_live_stream_id is not null then
    update public.live_streams set gift_coin_total = gift_coin_total + v_price::bigint * v_qty where id = p_live_stream_id;

    select name into v_receiver_name from public.profiles where id = p_receiver_id;
    insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, gift_id, gift_count, gift_receiver_ids)
      values (
        p_live_stream_id,
        v_sender,
        'sent ' ||
          case when p_receiver_id = v_sender then '' else coalesce(v_receiver_name, 'someone') || ' ' end ||
          case when v_qty > 1 then v_qty || 'x ' else '' end ||
          v_gift_name || ' ' || v_gift_emoji,
        'gift',
        p_gift_id,
        v_qty,
        array[p_receiver_id]
      );
  end if;

  return v_qty;
end;
$$;
revoke execute on function public.send_gift_v2(uuid, uuid, uuid, integer) from public, anon;
grant execute on function public.send_gift_v2(uuid, uuid, uuid, integer) to authenticated;

create or replace function public.send_gift_to_all_v2(p_gift_id uuid, p_live_stream_id uuid, p_quantity integer default 1)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_qty integer := coalesce(p_quantity, 1);
  v_price integer;
  v_gift_name text;
  v_gift_emoji text;
  v_host uuid;
  v_status text;
  v_recipients uuid[];
  v_n integer;
  v_receiver uuid;
  v_i integer;
begin
  if v_sender is null then
    raise exception 'Must be signed in to send a gift';
  end if;
  if v_qty < 1 or v_qty > 99 then
    raise exception 'Pick a quantity from 1 to 99';
  end if;

  select host_id, status into v_host, v_status from public.live_streams where id = p_live_stream_id;
  if v_host is null then
    raise exception 'This live no longer exists';
  end if;
  if v_status is distinct from 'live' then
    raise exception 'This live has ended';
  end if;

  select price_coins, name, emoji into v_price, v_gift_name, v_gift_emoji
    from public.gifts where id = p_gift_id and status = 'active';
  if v_price is null then
    raise exception 'Unknown or inactive gift';
  end if;

  -- everyone worth gifting: the host and whoever is on a seat, except the sender
  select array_agg(r.id) into v_recipients
    from (
      select v_host as id
      union
      select s.occupant_id from public.live_stream_seats s where s.live_stream_id = p_live_stream_id
    ) r
   where r.id <> v_sender;
  v_n := coalesce(cardinality(v_recipients), 0);
  if v_n = 0 then
    raise exception 'There is no one else here to send this to';
  end if;

  if coalesce((select coins from public.wallets where profile_id = v_sender), 0) < v_price::bigint * v_n * v_qty then
    raise exception 'Insufficient coins';
  end if;

  foreach v_receiver in array v_recipients loop
    for v_i in 1..v_qty loop
      insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
        values (v_sender, 'gift_sent', 'coins', -v_price, 'gift_transactions', 'Gift sent');
      insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
        values (v_receiver, 'gift_received', 'diamonds', v_price, 'gift_transactions', 'Gift received');
      insert into public.gift_transactions (live_stream_id, sender_id, receiver_id, gift_id, coins)
        values (p_live_stream_id, v_sender, v_receiver, p_gift_id, v_price);
    end loop;
  end loop;

  update public.live_streams set gift_coin_total = gift_coin_total + v_price::bigint * v_n * v_qty
   where id = p_live_stream_id;

  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, gift_id, to_all, gift_count, gift_receiver_ids)
    values (p_live_stream_id, v_sender,
            'sent ' || v_qty || 'x ' || v_gift_name || ' ' || v_gift_emoji || ' to ' || v_n || case when v_n = 1 then ' person' else ' people' end,
            'gift', p_gift_id, true, v_qty, v_recipients);

  return v_n;
end;
$$;
revoke execute on function public.send_gift_to_all_v2(uuid, uuid, integer) from public, anon;
grant execute on function public.send_gift_to_all_v2(uuid, uuid, integer) to authenticated;
