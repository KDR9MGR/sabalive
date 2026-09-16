-- Extends the existing app_config singleton (already has brand_color, from
-- the admin panel's Application Configuration screen, but the app never
-- read it) with the rest of what the app needs to re-theme itself live:
-- an accent colour and a font family. World-readable / admin-writable
-- policies already cover this table — nothing new needed there.
alter table public.app_config
  add column accent_color text not null default '#F5279B',
  add column font_family text not null default 'Poppins';
