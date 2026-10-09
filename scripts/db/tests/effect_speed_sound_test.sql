-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/effect_speed_sound_test.sql
insert into public.gifts (id, name, emoji, price_coins) values ('97979797-9797-9797-9797-979797979797', 'Speedy', 'S', 5);
select '1 an untouched gift has no speed and no sound (expect t, t)' as check, play_speed is null as no_speed, sound_url is null as no_sound
  from public.gifts where id = '97979797-9797-9797-9797-979797979797';
update public.gifts set play_speed = 0.75, sound_url = 'https://x/s.mp3' where id = '97979797-9797-9797-9797-979797979797';
select '2 0.75 and a sound link are accepted (expect 0.75)' as check, play_speed as n from public.gifts where id = '97979797-9797-9797-9797-979797979797';
do $$ begin
  update public.gifts set play_speed = 5 where id = '97979797-9797-9797-9797-979797979797';
  raise exception 'expected a check violation';
exception when check_violation then null; end $$;
do $$ begin
  update public.gifts set play_speed = 0.05 where id = '97979797-9797-9797-9797-979797979797';
  raise exception 'expected a check violation';
exception when check_violation then null; end $$;
select '3 speeds outside 0.1-2 are refused (expect t)' as check, true as ok;
update public.store_items set play_speed = 2, sound_url = 'https://x/e.m4a' where id = (select id from public.store_items limit 1);
select '4 store_items has both columns too (expect 2)' as check, max(play_speed) as n from public.store_items;
select '5 the bucket accepts mp3 and m4a (expect t, t)' as check,
       'audio/mpeg' = any(allowed_mime_types) as mp3, 'audio/x-m4a' = any(allowed_mime_types) as m4a
  from storage.buckets where id = 'gift-assets';
