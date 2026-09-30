-- PK gift bursts were 100% local to whoever tapped send — the host's own
-- screen had no gift-burst code at all, and the viewer screen's burst only
-- ever played for the person who just sent it, never broadcast to anyone
-- else watching (not the host, not the opponent, not other viewers). Piggy-
-- backs on the pk_battles row both hosts + all viewers already subscribe
-- to for score/timer sync (subscribeBattle) — an incrementing sequence
-- number rather than just the emoji/side, so the client can tell a genuinely
-- new gift apart from an unrelated row update (e.g. the score changing for
-- a different reason) even if the same gift is sent twice in a row.
alter table public.pk_battles add column last_gift_id uuid references public.gifts (id);
alter table public.pk_battles add column last_gift_side text check (last_gift_side in ('a', 'b'));
alter table public.pk_battles add column last_gift_seq integer not null default 0;

create or replace function public.send_pk_gift(p_battle_id uuid, p_side text, p_gift_id uuid)
returns public.gift_transactions
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_battle public.pk_battles%rowtype;
  v_receiver uuid;
  v_receiver_stream uuid;
  v_tx public.gift_transactions;
begin
  if v_me is null then
    raise exception 'Must be signed in to send a gift';
  end if;
  if p_side not in ('a', 'b') then
    raise exception 'Invalid side';
  end if;

  select * into v_battle from public.pk_battles where id = p_battle_id;
  if not found then
    raise exception 'Battle not found';
  end if;
  if v_battle.status <> 'live' then
    raise exception 'This battle is not live';
  end if;
  if v_battle.ends_at is null or now() >= v_battle.ends_at then
    raise exception 'This battle has ended';
  end if;

  if p_side = 'a' then
    v_receiver := v_battle.host_a_id;
    v_receiver_stream := v_battle.stream_a_id;
  else
    v_receiver := v_battle.host_b_id;
    v_receiver_stream := v_battle.stream_b_id;
  end if;

  v_tx := public.send_gift(p_gift_id, v_receiver, v_receiver_stream);

  if p_side = 'a' then
    update public.pk_battles
    set score_a = score_a + v_tx.coins,
        last_gift_id = p_gift_id, last_gift_side = p_side, last_gift_seq = last_gift_seq + 1
    where id = p_battle_id;
  else
    update public.pk_battles
    set score_b = score_b + v_tx.coins,
        last_gift_id = p_gift_id, last_gift_side = p_side, last_gift_seq = last_gift_seq + 1
    where id = p_battle_id;
  end if;

  return v_tx;
end;
$$;
