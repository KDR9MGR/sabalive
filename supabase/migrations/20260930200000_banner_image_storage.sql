-- Public-read storage bucket for banner images, uploaded from the admin
-- panel (Content / Settings > Banners). Unlike avatars, these aren't owned
-- by a particular user's folder — any admin-or-above may upload/replace/
-- delete any banner image, matching who may already manage the banners
-- table itself (public.banners has no RLS restricting writes beyond the
-- app's own admin gate).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('banners', 'banners', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "Banner images are publicly readable"
  on storage.objects for select
  using (bucket_id = 'banners');

create policy "Admins manage banner images"
  on storage.objects for all
  using (bucket_id = 'banners' and public.is_admin_or_above())
  with check (bucket_id = 'banners' and public.is_admin_or_above());
