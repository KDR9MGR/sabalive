-- Two fixes found while investigating the live-room slowness reports.
--
-- 1. dev_purchase_coins was an alpha-stage test RPC that credits coins with no
--    payment. The app's Pay button is switched off by a feature flag, but the RPC
--    itself was still executable by every signed-in user, so anyone with a custom
--    client could mint themselves coins. Nothing has used it (no wallet_ledger rows
--    carry its note), so closing it changes nothing for real users. A payment
--    gateway, when it lands, will credit coins from a server-side function instead.
revoke execute on function public.dev_purchase_coins(uuid) from public, anon, authenticated;

-- 2. live_streams.ended_at was written by the host's phone as local wall-clock time
--    with no zone (DateTime.now().toIso8601String()), which Postgres reads as UTC.
--    A host in India therefore "ended" 5.5 hours in the future; hosts in other zones
--    ended hours in the past. That inflated every live-duration figure in the panel
--    reports. The server now stamps the end time itself, whatever the client sends,
--    so builds already in the field are covered too.
create or replace function public.live_streams_stamp_ended_at()
returns trigger
language plpgsql
as $$
begin
  if old.status is distinct from 'ended' or new.ended_at is null then
    -- the moment the stream actually ends (host pressed End, or the sweeper)
    new.ended_at := now();
  elsif new.ended_at is distinct from old.ended_at then
    -- an already-ended row being edited: never accept an end time in the future
    new.ended_at := least(new.ended_at, now());
  end if;
  return new;
end;
$$;

drop trigger if exists live_streams_stamp_ended_at on public.live_streams;
create trigger live_streams_stamp_ended_at
  before update on public.live_streams
  for each row
  when (new.status = 'ended')
  execute function public.live_streams_stamp_ended_at();

-- Repair the rows the bug already wrote. A host app beats the stream heartbeat every
-- ~30 s and the sweeper ends a silent stream within ~10 minutes, so a genuine end is
-- always within 15 minutes of the last heartbeat; anything further out is the timezone
-- error. The last heartbeat is the best available end time. Only streams from after
-- the heartbeat feature shipped (2026-09-16) are touched.
update public.live_streams
   set ended_at = greatest(started_at, last_heartbeat_at)
 where status = 'ended'
   and started_at >= '2026-09-17'
   and last_heartbeat_at is not null
   and abs(extract(epoch from (ended_at - last_heartbeat_at))) > 900;
