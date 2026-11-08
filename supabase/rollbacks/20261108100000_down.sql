-- Down script for supabase/migrations/20261108100000_upload_limit_35mb.sql
-- Cannot be undone by this script: files bigger than 15 MB uploaded meanwhile stay where they are (they just cannot be replaced by another that size).
begin;
set local lock_timeout = '5s';
update storage.buckets set file_size_limit = 15728640 where id in ('gift-assets', 'banners');
commit;
