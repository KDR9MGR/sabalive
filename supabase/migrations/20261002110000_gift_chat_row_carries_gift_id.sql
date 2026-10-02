-- A gift sent in a live room was only ever a text line ("sent Rose 🌹") for
-- everyone but the sender, so viewers and the host never saw the gift itself
-- on screen. The chat row now records WHICH gift it was, so each device can
-- look the gift up (with its uploaded SVGA / MP4 / WebP artwork) and play it.
-- Nullable and on delete set null: every existing row, and any text/system
-- row, simply has no gift to play.
alter table public.live_chat_messages
  add column if not exists gift_id uuid references public.gifts (id) on delete set null;

create or replace function public.send_gift(p_gift_id uuid, p_receiver_id uuid, p_live_stream_id uuid default null)
returns public.gift_transactions
language plpgsql security definer set search_path = public
as $$
declare
  v_price integer;
  v_gift_name text;
  v_gift_emoji text;
  v_receiver_name text;
  v_sender uuid := auth.uid();
  v_tx public.gift_transactions;
begin
  if v_sender is null then
    raise exception 'Must be signed in to send a gift';
  end if;

  select price_coins, name, emoji into v_price, v_gift_name, v_gift_emoji
    from public.gifts where id = p_gift_id and status = 'active';
  if v_price is null then
    raise exception 'Unknown or inactive gift';
  end if;

  if (select coins from public.wallets where profile_id = v_sender) < v_price then
    raise exception 'Insufficient coins';
  end if;

  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (v_sender, 'gift_sent', 'coins', -v_price, 'gift_transactions', 'Gift sent');
  insert into public.wallet_ledger (profile_id, kind, currency, amount, reference_table, note)
    values (p_receiver_id, 'gift_received', 'diamonds', v_price, 'gift_transactions', 'Gift received');

  insert into public.gift_transactions (live_stream_id, sender_id, receiver_id, gift_id, coins)
    values (p_live_stream_id, v_sender, p_receiver_id, p_gift_id, v_price)
    returning * into v_tx;

  if p_live_stream_id is not null then
    update public.live_streams set gift_coin_total = gift_coin_total + v_price where id = p_live_stream_id;

    select name into v_receiver_name from public.profiles where id = p_receiver_id;
    insert into public.live_chat_messages (live_stream_id, sender_id, body, kind, gift_id)
      values (
        p_live_stream_id,
        v_sender,
        case
          when p_receiver_id = v_sender then 'sent ' || v_gift_name || ' ' || v_gift_emoji
          else 'sent ' || coalesce(v_receiver_name, 'someone') || ' ' || v_gift_name || ' ' || v_gift_emoji
        end,
        'gift',
        p_gift_id
      );
  end if;

  return v_tx;
end;
$$;
