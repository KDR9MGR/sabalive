-- Real uploaded visual assets (SVGA / WebP / MP4 / PNG) for gifts, badges,
-- profile frames and leaderboard frames, alongside the existing plain-text
-- emoji fallback (kept NOT NULL and still the default shown when no asset
-- is uploaded — nothing existing breaks).
alter table public.gifts add column icon_url text;
alter table public.badges add column icon_url text;
alter table public.frames add column icon_url text;
alter table public.leaderboard_frames add column icon_url text;

-- Shared bucket for these four. SVGA has no registered MIME type, so an
-- upload of a .svga file is sent as application/octet-stream — this bucket
-- is admin-write-only, so accepting that type broadly here is low risk.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gift-assets', 'gift-assets', true, 15728640, array['image/png', 'image/webp', 'video/mp4', 'application/octet-stream'])
on conflict (id) do nothing;

create policy "Gift assets are publicly readable"
  on storage.objects for select
  using (bucket_id = 'gift-assets');

create policy "Admins manage gift assets"
  on storage.objects for all
  using (bucket_id = 'gift-assets' and public.is_admin_or_above())
  with check (bucket_id = 'gift-assets' and public.is_admin_or_above());

-- Banners get the same format set (animated banners), not just static images.
update storage.buckets
   set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'application/octet-stream'],
       file_size_limit = 15728640
 where id = 'banners';
