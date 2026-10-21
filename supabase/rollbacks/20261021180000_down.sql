-- Down script for supabase/migrations/20261021180000_fans_mutual_follow.sql
-- Applied BY HAND only, when that migration has to be undone.
--
-- Removes the fans trigger, its function and the Fans list function. The fans_count column stays (it existed before this migration) and
-- is set back to 0 for everyone, which is what it always was; the apps then show 0 Fans again and the Fans list shows an error until the
-- apps are updated. Nothing else uses these objects.
begin;
set local lock_timeout = '5s';

drop trigger if exists follows_fans_after_change on public.follows;
drop function if exists public.handle_fans_change();
drop function if exists public.get_fans(uuid, integer);
update public.profiles set fans_count = 0 where fans_count <> 0;

commit;
