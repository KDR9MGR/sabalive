-- An agency gets its own photo (like a logo), editable in the panel's Agency edit form (Master / Super Admin) and shown in the Agency list and its details.
-- One nullable text column on the small agencies table (an address in the gift-assets storage bucket, like every other panel upload); nothing reads it but the panel,
-- so the app and old app versions are untouched. Rollback: supabase/rollbacks/20261124100000_down.sql.
set local lock_timeout = '5s';

alter table public.agencies add column if not exists avatar_url text;
