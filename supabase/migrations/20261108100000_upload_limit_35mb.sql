-- Panel asset uploads (gift / badge / frame / store / banner artwork, effect sounds) may be up to 35 MB instead of 15 MB.
-- Only the two panel buckets change; the app's own `avatars` bucket stays at 5 MB. Raising a limit breaks nothing that exists.
update storage.buckets set file_size_limit = 36700160 where id in ('gift-assets', 'banners');   -- 35 * 1024 * 1024
