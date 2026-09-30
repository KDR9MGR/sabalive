-- Banners can now carry a tap-through destination — the home_top banner
-- slot is admin-pushed ad content only now (the old hardcoded "Welcome
-- back" text banner was removed client-side), and an ad without a
-- click-through destination isn't much of an ad.
alter table public.banners add column link_url text;
