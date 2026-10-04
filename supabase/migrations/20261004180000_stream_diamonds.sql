-- "Diamonds earned in this stream today", shown under each seat in an audio room.
--
-- Per stream, per receiver: the diamonds (a gift's coins are credited 1:1 as
-- diamonds) received in gifts sent in THAT stream since 00:00 UTC. It is always
-- derived from gift_transactions, so a user who leaves and comes back to the same
-- stream resumes the same number, a different stream has its own count, and at
-- 00:00 UTC every count starts again from 0 — the same moment for everyone, not
-- per user.
create index if not exists gift_transactions_stream_receiver_idx
  on public.gift_transactions (live_stream_id, receiver_id, created_at);

create or replace function public.stream_diamonds_today(p_stream_id uuid)
returns table (user_id uuid, diamonds bigint)
language sql stable security definer set search_path = public
as $$
  select t.receiver_id, sum(t.coins)::bigint
    from public.gift_transactions t
   where t.live_stream_id = p_stream_id
     and t.created_at >= (date_trunc('day', now() at time zone 'utc') at time zone 'utc')
   group by t.receiver_id;
$$;
revoke execute on function public.stream_diamonds_today(uuid) from public, anon;
grant execute on function public.stream_diamonds_today(uuid) to authenticated;
