-- Per-user PK Battle arena background — a fixed palette (same gradient set
-- already used for avatar tints, AppColors.tints, so it stays visually
-- consistent with the rest of the app rather than inventing a new one).
-- Nullable: null means "use the existing default look", so nobody who
-- hasn't touched this sees any visual change.
alter table public.profiles add column pk_wallpaper integer check (pk_wallpaper between 0 and 7);
grant update (pk_wallpaper) on public.profiles to authenticated;
