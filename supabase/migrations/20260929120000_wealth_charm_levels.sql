-- Wealth & Charm levels — a separate pair of tracks from the existing
-- combined profiles.xp/level (which stays exactly as-is: it's the "LV X"
-- badge shown everywhere next to a username, fed by both sending AND
-- receiving, and changing that now would ripple through every screen that
-- already renders it). Wealth tracks coins SPENT (sender side), Charm
-- tracks value RECEIVED (receiver side) — the two-track split common to
-- this kind of app, per Rey (2026-09-29), both going to level 100.
--
-- level_thresholds only had rows through level 20 (20260923190000) —
-- extended here to 100 using the exact same formula the original 20 rows
-- already followed (xp_required = 500 * (level-1)^2, verified against
-- every existing row before writing this). This also happens to lift the
-- combined xp/level's own implicit cap of 20 — previously anyone who
-- earned past 180,500 xp just stayed stuck showing "LV 20" forever since
-- no higher threshold row existed; that was never an intentional cap.
insert into public.level_thresholds (level, xp_required)
select n, 500 * (n - 1) * (n - 1)
from generate_series(21, 100) as n;

alter table public.profiles add column wealth_xp integer not null default 0;
alter table public.profiles add column wealth_level integer not null default 1;
alter table public.profiles add column charm_xp integer not null default 0;
alter table public.profiles add column charm_level integer not null default 1;

create function public.award_wealth_charm_xp()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update public.profiles set
    wealth_xp = wealth_xp + new.coins,
    wealth_level = (
      select max(level) from public.level_thresholds
      where xp_required <= profiles.wealth_xp + new.coins
    )
  where id = new.sender_id;

  update public.profiles set
    charm_xp = charm_xp + new.coins,
    charm_level = (
      select max(level) from public.level_thresholds
      where xp_required <= profiles.charm_xp + new.coins
    )
  where id = new.receiver_id;

  return new;
end;
$$;

create trigger award_wealth_charm_xp_trigger
after insert on public.gift_transactions
for each row execute function public.award_wealth_charm_xp();
