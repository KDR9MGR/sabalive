-- Games list: what the app needs to sort by "Newest / Oldest" and "Most played". EVERYTHING HERE IS NEW; no existing function changes.
--
--  1. added_at          when a game was first stored, on merchant_games (Tulasi) and sud_games. A new column with a default: every game that exists today
--                       gets the time of this migration (they tie: the app breaks the tie by id, which grows with time), every game stored later gets
--                       its own time. A Tulasi sync and the panel's save of a SUD game never touch it (their upserts do not list the column).
--  2. game_plays        one row each time a person opens a game (the app calls record_game_play after a launch went through): no policy, only the functions
--                       read it. Kept 30 days.
--  3. game_popularity   how many times / by how many people each game was opened in the last 14 days: a tiny table (one row per game) the app reads. It is
--                       rebuilt every 15 minutes by pg_cron (refresh_game_popularity), so no phone ever counts game_plays itself.
-- game_id is the app's id of the game (merchant_games.id for Tulasi, sud_games.id for SUD: SUD's start at 1,000,000, so they never meet).
-- Old app builds know none of this. Rollback: supabase/rollbacks/20261028100000_down.sql

set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1. when a game was first stored
-- ---------------------------------------------------------------------------
alter table public.merchant_games add column if not exists added_at timestamptz not null default now();
alter table public.sud_games add column if not exists added_at timestamptz not null default now();

-- ---------------------------------------------------------------------------
-- 2. every time a game is opened
-- ---------------------------------------------------------------------------
create table if not exists public.game_plays (
  id bigint generated always as identity primary key,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  game_id bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists game_plays_game_idx on public.game_plays (game_id, created_at desc);
create index if not exists game_plays_created_idx on public.game_plays (created_at);
create index if not exists game_plays_profile_idx on public.game_plays (profile_id, game_id, created_at desc);
alter table public.game_plays enable row level security;   -- no policy at all: only the functions below touch it

-- The app calls this after a launch succeeded. It never fails the app: a ghost, an unknown or switched-off game, or the same person opening the same game
-- again within a minute simply is not counted.
create or replace function public.record_game_play(p_game_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null or p_game_id is null then
    return;
  end if;
  if public.is_ghost(v_me) then
    return;
  end if;
  if not exists (select 1 from public.merchant_games where id = p_game_id and status = 1 and not hidden)
     and not exists (select 1 from public.sud_games where id = p_game_id and status = 1 and not hidden) then
    return;
  end if;
  if exists (
    select 1 from public.game_plays
    where profile_id = v_me and game_id = p_game_id and created_at > now() - interval '60 seconds'
  ) then
    return;
  end if;
  insert into public.game_plays (profile_id, game_id) values (v_me, p_game_id);
end;
$$;
revoke execute on function public.record_game_play(bigint) from public, anon;
grant execute on function public.record_game_play(bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. the numbers the app shows the order of
-- ---------------------------------------------------------------------------
create table if not exists public.game_popularity (
  game_id bigint primary key,
  plays integer not null default 0,       -- times opened in the last 14 days
  players integer not null default 0,     -- different people who opened it
  updated_at timestamptz not null default now()
);
alter table public.game_popularity enable row level security;
drop policy if exists "Signed-in users read the game popularity" on public.game_popularity;
create policy "Signed-in users read the game popularity" on public.game_popularity for select to authenticated using (true);

create or replace function public.refresh_game_popularity()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  delete from public.game_plays where created_at < now() - interval '30 days';
  delete from public.game_popularity;
  insert into public.game_popularity (game_id, plays, players)
  select game_id, count(*)::integer, count(distinct profile_id)::integer
  from public.game_plays
  where created_at >= now() - interval '14 days'
  group by game_id;
end;
$$;
revoke execute on function public.refresh_game_popularity() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('refresh-game-popularity');
exception when others then null;
end $$;
select cron.schedule('refresh-game-popularity', '*/15 * * * *', $cron$ select public.refresh_game_popularity() $cron$);
