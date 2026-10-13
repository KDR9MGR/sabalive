-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/more_live_emotes_test.sql
-- Proves: the migration added the new emotes after the original 10, in order, and running its insert again adds nothing.
select '1 original + new emotes (expect 63)' as check, count(*) as n from public.live_emojis where kind = 'emoji';
select '1b the original ones are first (expect t)' as check, bool_and(sort_order <= 10) as ok from public.live_emojis where label in ('Heart', 'Fire', 'Pray');
select '1c new ones come after them, all different orders (expect t)' as check,
       min(sort_order) > 10 and count(distinct sort_order) = count(*) as ok
  from public.live_emojis where label in ('Grin', 'Cake', 'Music');
select '1d ordered as listed (expect t)' as check,
       (select sort_order from public.live_emojis where label = 'Grin') < (select sort_order from public.live_emojis where label = 'Music') as ok;

-- a second run (re-applying the file) adds nothing
\i supabase/migrations/20261012110000_more_live_emotes.sql
select '2 re-run adds nothing (expect 63)' as check, count(*) as n from public.live_emojis where kind = 'emoji';

-- an emoji an admin already added by hand is not duplicated
delete from public.live_emojis where emoji = '🚀';
insert into public.live_emojis (kind, label, emoji, sort_order) values ('emoji', 'My rocket', '🚀', 999);
\i supabase/migrations/20261012110000_more_live_emotes.sql
select '3 a hand-made emote with the same emoji is kept, not doubled (expect 1)' as check, count(*) as n from public.live_emojis where emoji = '🚀';
