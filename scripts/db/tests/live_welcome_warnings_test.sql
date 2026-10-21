-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/live_welcome_warnings_test.sql
-- Proves the welcome-warning columns (migration 20261020110000), for the video AND the audio warning: each switch defaults to ON, each text to empty, a text up
-- to 600 characters is kept, a longer one is refused, the two are independent, and nothing else on app_config moves.

create or replace function pg_temp.raises(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'NOT raised';
exception when others then
  return 'raised: ' || sqlerrm;
end;
$$;

select '1 the four columns exist (expect 4)' as check, count(*) as n from information_schema.columns
  where table_schema = 'public' and table_name = 'app_config' and column_name in ('video_warning_enabled', 'video_warning_text', 'audio_warning_enabled', 'audio_warning_text');
select '1 a row from before the migration: both ON, no texts (expect true, true, true, true)' as check,
  video_warning_enabled as video_on, video_warning_text is null as video_no_text, audio_warning_enabled as audio_on, audio_warning_text is null as audio_no_text from public.app_config;

select '2 the video switch can be turned off (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set video_warning_enabled = false$$) as result;
select '2 and only that one moved (expect false, true)' as check, video_warning_enabled as video_on, audio_warning_enabled as audio_on from public.app_config;
select '2 the audio switch can be turned off too (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set audio_warning_enabled = false$$) as result;
select '2 neither can be emptied (expect raised, raised)' as check,
  pg_temp.raises($$update public.app_config set video_warning_enabled = null$$) as video, pg_temp.raises($$update public.app_config set audio_warning_enabled = null$$) as audio;

select '3 a video text and an audio text are kept apart (expect NOT raised)' as check,
  pg_temp.raises($$update public.app_config set video_warning_text = 'Video rules.', audio_warning_text = 'Audio rules.'$$) as result;
select '3 and they read back (expect Video rules., Audio rules.)' as check, video_warning_text, audio_warning_text from public.app_config;
select '3 exactly 600 characters are accepted in each (expect NOT raised, NOT raised)' as check,
  pg_temp.raises($$update public.app_config set video_warning_text = repeat('x', 600)$$) as video, pg_temp.raises($$update public.app_config set audio_warning_text = repeat('y', 600)$$) as audio;
select '3 601 characters are refused in each (expect raised, raised)' as check,
  pg_temp.raises($$update public.app_config set video_warning_text = repeat('x', 601)$$) as video, pg_temp.raises($$update public.app_config set audio_warning_text = repeat('y', 601)$$) as audio;
select '3 the refused saves changed nothing (expect 600, 600)' as check, char_length(video_warning_text) as video_chars, char_length(audio_warning_text) as audio_chars from public.app_config;
select '4 each text can be cleared back to the built-in one (expect NOT raised, NOT raised)' as check,
  pg_temp.raises($$update public.app_config set video_warning_text = null$$) as video, pg_temp.raises($$update public.app_config set audio_warning_text = null$$) as audio;
select '4 and both are empty (expect true, true)' as check, video_warning_text is null as video_empty, audio_warning_text is null as audio_empty from public.app_config;
select '5 the other settings are untouched (expect a brand colour, a font)' as check, brand_color, font_family from public.app_config;
