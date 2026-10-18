-- Down script for supabase/migrations/20261019100000_seat_requests_and_give_up.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Cannot be undone by this script: requests already written to pk_seat_requests stay (they are ordinary rows), and a battle that was
-- ended with pk_give_up_v2 stays finished. The apps fall back to self-serve seats (claim_seat) when the request function is not there,
-- and say "not available yet" for End PK, so dropping these does not break anyone.
begin;
set local lock_timeout = '5s';

drop function if exists public.pk_give_up_v2(uuid);
drop function if exists public.clear_seat_requests_v2(uuid);
drop function if exists public.request_seat_v2(uuid);
drop function if exists public.set_seat_requests_v2(uuid, boolean);
-- the column goes last; nothing reads it once the functions are gone
alter table public.live_streams drop column if exists seat_requests;

commit;
