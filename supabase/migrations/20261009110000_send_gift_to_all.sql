-- "Send to All": one gift to everyone in the room, as ONE action.
--
-- Before, the app looped over everyone and called send_gift once per person: N round trips, a failure halfway
-- left some people gifted and others not, the balance was only checked one gift at a time, and the room saw N
-- chat lines ("sent <person> Rose" for each). Now the server does it atomically: it works out who is in the room
-- (the host and everyone on a seat, never the sender), checks the balance for price x people up front, writes the
-- same ledger and gift rows send_gift writes (so levels, diamonds and the host totals behave exactly the same),
-- and posts a single line: "<sender> sent Rose to All".
--
-- Additive: a new function and a new column with a constant default. send_gift is untouched, so every installed
-- app version keeps working; apps that don't know the new function simply keep looping send_gift.
alter table public.live_chat_messages
  add column if not exists to_all boolean not null default false;

create or replace function public.send_gift_to_all(p_gift_id uuid, p_live_stream_id uuid)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_price integer;
  v_gift_name text;
  v_gift_emoji text;
  v_host uuid;
  v_status text;
  v_recipients uuid[];
  v_n integer;
  v_receiver uuid;
begin
  if v_sender is null then
    raise exception 'Must be signed in to send a gift';
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

  if coalesce((select coins from public.wallets where profile_id = v_sender), 0) < v_price::bigint * v_n then
    raise exception 'Insufficient coins';
  end if;

  foreach v_receiver in array v_recipients loop
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
      values (v_sender, 'gift_sent', 'coins', -v_price, 'gift_transactions', 'Gift sent');
    insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
      values (v_receiver, 'gift_received', 'diamonds', v_price, 'gift_transactions', 'Gift received');
    insert into public.gift_transactions (live_stream_id, sender_id, receiver_id, gift_id, coins)
      values (p_live_stream_id, v_sender, v_receiver, p_gift_id, v_price);
  end loop;

  update public.live_streams set gift_coin_total = gift_coin_total + v_price::bigint * v_n
   where id = p_live_stream_id;

  insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, gift_id, to_all)
    values (p_live_stream_id, v_sender, 'sent ' || v_gift_name || ' ' || v_gift_emoji || ' to All', 'gift', p_gift_id, true);

  return v_n;
end;
$$;

-- Supabase hands EXECUTE to anon explicitly on new functions, which "from public" does not remove
revoke execute on function public.send_gift_to_all(uuid, uuid) from public, anon;
grant execute on function public.send_gift_to_all(uuid, uuid) to authenticated;
