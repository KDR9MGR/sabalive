-- Levels/XP. profiles.level already existed but was never actually
-- earned — always whatever it defaulted to. Wired it to real gift
-- activity: sending OR receiving a gift earns XP equal to its coin
-- value, both sides, since both are "engagement" on this platform.
-- Thresholds live in a table (not a hardcoded formula) so the
-- progression can be retuned later without a code change — same
-- reasoning as gifts/coin_packages being catalog tables, not constants.
create table public.level_thresholds (
  level integer primary key,
  xp_required integer not null
);

insert into public.level_thresholds (level, xp_required) values
  (1, 0), (2, 500), (3, 2000), (4, 4500), (5, 8000), (6, 12500),
  (7, 18000), (8, 24500), (9, 32000), (10, 40500), (11, 50000),
  (12, 60500), (13, 72000), (14, 84500), (15, 98000), (16, 112500),
  (17, 128000), (18, 144500), (19, 162000), (20, 180500);

alter table public.level_thresholds enable row level security;
create policy "Level thresholds are viewable by everyone"
  on public.level_thresholds for select using (true);

alter table public.profiles add column xp integer not null default 0;

create function public.award_gift_xp()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- xp on the right of "=" and inside the level subquery both see this
  -- row's pre-update value within one UPDATE statement, so both correctly
  -- compute off the same new total (old xp + this gift's coins).
  update public.profiles set
    xp = xp + new.coins,
    level = (
      select max(level) from public.level_thresholds
      where xp_required <= profiles.xp + new.coins
    )
  where id in (new.sender_id, new.receiver_id);
  return new;
end;
$$;

create trigger award_gift_xp_trigger
after insert on public.gift_transactions
for each row execute function public.award_gift_xp();
