-- Game win notices (owner, 2026-11-07: "for any user winning 5,000 coins it should trigger" the notification strip).
--
-- A game round is not tied to a live room on the server, so a win strip cannot come from a room's own rows. This is a platform-wide feed instead: whenever ANY person is paid
-- a game win of at least game_win_notice_min_coins() coins (5,000), one row lands in game_win_notices, and every phone that is inside a live room hears about it over Realtime
-- and draws the strip (the owner's strip file, winner on the left, the game on the right, "+5,000" on the coin).
--
-- Additive only: a new table, two new functions and a trigger on game_transactions that fires ONLY when a row becomes an accepted win of that size (a bet, a small win, a
-- rejected row and a repeat never reach it). The trigger swallows every error: a notice problem must never stop a game payout. Old apps never read the table.
-- Both providers write a round the same way (insert 'pending', then update status to 'ok': game_apply_balance for Tulasi, sud_apply_score for SUD), so one trigger covers both.
-- Rollback: supabase/rollbacks/20261107100000_down.sql.

-- The size of a win that gets a strip: the ONE place the number lives (the app shows whatever rows arrive).
create or replace function public.game_win_notice_min_coins()
returns bigint language sql immutable
as $$ select 5000::bigint $$;

create table if not exists public.game_win_notices (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  winner_name text not null,
  winner_avatar_url text,
  game_name text,
  game_image_url text,
  coins bigint not null check (coins > 0),
  created_at timestamptz not null default now()
);
create index if not exists game_win_notices_created_idx on public.game_win_notices (created_at desc);
comment on table public.game_win_notices is 'One row per game win of at least game_win_notice_min_coins() coins, written only by the trigger on game_transactions; phones in a live room read it over Realtime to draw the notification strip. Rows older than 2 days are removed by the next insert.';

alter table public.game_win_notices enable row level security;
revoke all on public.game_win_notices from public, anon, authenticated;
grant select on public.game_win_notices to authenticated;
drop policy if exists "Signed-in users see big game wins" on public.game_win_notices;
create policy "Signed-in users see big game wins" on public.game_win_notices for select to authenticated using (true);

create or replace function public._game_win_notice_after_win()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_name text;
  v_avatar text;
  v_ghost boolean;
  v_game text;
  v_image text;
begin
  select name, avatar_url, coalesce(is_ghost, false) into v_name, v_avatar, v_ghost from public.profiles where id = new.profile_id;
  if not found or v_ghost then
    return new;   -- a monitoring (ghost) account never shows up in public
  end if;
  if coalesce(new.game_type, '') like 'sud:%' then
    select name, image_url into v_game, v_image from public.sud_games where provider_game_id = new.game_id;
  elsif coalesce(new.game_id, '') ~ '^[0-9]{1,18}$' then
    select name, image_url into v_game, v_image from public.merchant_games where id = new.game_id::bigint;
  end if;
  insert into public.game_win_notices (profile_id, winner_name, winner_avatar_url, game_name, game_image_url, coins)
  values (new.profile_id, coalesce(nullif(btrim(v_name), ''), 'Someone'), v_avatar, v_game, v_image, new.coin);
  delete from public.game_win_notices where created_at < now() - interval '2 days';
  return new;
exception when others then
  return new;   -- never let a notice problem touch a game payout
end;
$$;
revoke execute on function public._game_win_notice_after_win() from public, anon, authenticated;

drop trigger if exists game_transactions_win_notice on public.game_transactions;
create trigger game_transactions_win_notice
  after update of status on public.game_transactions
  for each row
  when (new.status = 'ok' and old.status is distinct from 'ok' and new.type = 1 and new.coin >= public.game_win_notice_min_coins())
  execute function public._game_win_notice_after_win();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'game_win_notices') then
    alter publication supabase_realtime add table public.game_win_notices;
  end if;
end $$;
