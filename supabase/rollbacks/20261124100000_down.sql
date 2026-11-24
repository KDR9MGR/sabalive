-- Undoes 20261124100000_agency_photo: the agencies' own photos are dropped (the panel keeps working, it just shows the initials again).
set local lock_timeout = '5s';
alter table public.agencies drop column if exists avatar_url;
