-- Gift and entry effects: how fast they play, and an optional sound that plays with them.
--
-- play_speed: 1 = the file's own speed, 0.75 = a quarter slower. Null means "use the app default" (0.75), so every
--   existing gift and entry effect becomes a little slower and smoother without anyone editing it. Allowed 0.1-2.
-- sound_url: an audio file (mp3/m4a/aac/wav/ogg) uploaded in the panel; every device in the room plays it with the
--   effect. When it is set the app mutes the video's own soundtrack so the two don't fight.
-- Additive (nullable columns, a wider list of accepted uploads): installed apps ignore what they don't know.
alter table public.gifts
  add column if not exists play_speed numeric(3,2) check (play_speed is null or (play_speed >= 0.1 and play_speed <= 2)),
  add column if not exists sound_url text;
alter table public.store_items
  add column if not exists play_speed numeric(3,2) check (play_speed is null or (play_speed >= 0.1 and play_speed <= 2)),
  add column if not exists sound_url text;

-- the same bucket the artwork goes into (15 MB limit already), now also accepting audio
update storage.buckets
   set allowed_mime_types = array[
         'image/png', 'image/webp', 'image/gif', 'image/jpeg', 'video/mp4',
         'audio/mpeg', 'audio/mp3', 'audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/wav', 'audio/x-wav', 'audio/ogg',
         'application/octet-stream'
       ]
 where id = 'gift-assets';
