-- Live hearts (owner, 2026-11-07: "like preview and count sync; sum of all users like and hearts should be seen by all").
--
-- Until now a tap on the heart in a live room only counted on the tapper's own phone (and flipped that person's like on / off in stream_likes, which drives like_count = the number of
-- different people who liked). Nobody else saw the hearts or the number move. This adds ONE small row per live that holds the SUM of every heart tapped in it by everybody:
--   live_hearts(live_stream_id, total, last_by, last_count, updated_at)   readable by signed-in users, written only by add_live_hearts()
--   add_live_hearts(stream, count)                                        a viewer's phone sends its taps in a batch (every ~3 s while tapping); 1..100 hearts a call
-- The row is in the Realtime publication; every phone in the live watches ONLY its own live's row (filtered), so it learns the new total and who added how many (last_by, last_count):
-- the other phones float that many hearts and set the number, the sender ignores its own echo. live_streams is NOT touched (it changes on every heartbeat and every list reloads on it),
-- and like_count / stream_likes stay exactly as they were for old apps.
-- Additive: a new table and a new function; old apps never read either. Rollback: supabase/rollbacks/20261107120000_down.sql.

create table if not exists public.live_hearts (
  live_stream_id uuid primary key references public.live_streams (id) on delete cascade,
  total bigint not null default 0 check (total >= 0),
  last_by uuid,
  last_count integer not null default 0,
  updated_at timestamptz not null default now()
);
comment on table public.live_hearts is 'The sum of every heart tapped in a live, by everybody; written only by add_live_hearts(); phones in the live watch their own row over Realtime.';

alter table public.live_hearts enable row level security;
revoke all on public.live_hearts from public, anon, authenticated;
grant select on public.live_hearts to authenticated;
drop policy if exists "Signed-in users see the hearts of a live" on public.live_hearts;
create policy "Signed-in users see the hearts of a live" on public.live_hearts for select to authenticated using (true);

-- Adds p_count hearts (1..100 a call, anything above is cut) to a LIVE stream and returns the new total; for a stream that is not live (or a count of 0 or less) it adds nothing and returns
-- the total as it is. A ghost (monitoring) account is view-only and may not send hearts; nobody signed out can.
create or replace function public.add_live_hearts(p_stream_id uuid, p_count integer)
returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_n integer;
  v_status text;
  v_total bigint;
begin
  if v_me is null then
    raise exception 'Sign in to send hearts';
  end if;
  if public.is_ghost(v_me) then
    raise exception 'This account cannot send hearts';
  end if;
  select status into v_status from public.live_streams where id = p_stream_id;
  if not found then
    raise exception 'That live does not exist';
  end if;
  v_n := least(greatest(coalesce(p_count, 0), 0), 100);
  if v_n = 0 or v_status is distinct from 'live' then
    return coalesce((select total from public.live_hearts where live_stream_id = p_stream_id), 0);
  end if;
  insert into public.live_hearts as h (live_stream_id, total, last_by, last_count)
  values (p_stream_id, v_n, v_me, v_n)
  on conflict (live_stream_id) do update
    set total = h.total + excluded.total, last_by = excluded.last_by, last_count = excluded.last_count, updated_at = now()
  returning h.total into v_total;
  return v_total;
end;
$$;
revoke execute on function public.add_live_hearts(uuid, integer) from public, anon;
grant execute on function public.add_live_hearts(uuid, integer) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'live_hearts') then
    alter publication supabase_realtime add table public.live_hearts;
  end if;
end $$;
