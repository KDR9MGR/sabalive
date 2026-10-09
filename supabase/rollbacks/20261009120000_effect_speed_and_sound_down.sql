-- Down script for supabase/migrations/20261009120000_effect_speed_and_sound.sql
-- Applied BY HAND only. Drops the two columns on both tables (losing any speeds and sound links entered since) and
-- puts the upload list back to what 20261002130000 set. Uploaded audio files stay in storage, unreferenced.
begin;
set local lock_timeout = '5s';
alter table public.gifts drop column if exists play_speed, drop column if exists sound_url;
alter table public.store_items drop column if exists play_speed, drop column if exists sound_url;
update storage.buckets
   set allowed_mime_types = array['image/png', 'image/webp', 'image/gif', 'image/jpeg', 'video/mp4', 'application/octet-stream']
 where id = 'gift-assets';
commit;
