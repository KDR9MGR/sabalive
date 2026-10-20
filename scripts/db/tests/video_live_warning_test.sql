-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/video_live_warning_test.sql
-- Proves the welcome-warning columns (migration 20261020110000): the switch defaults to ON, the text to empty, a text up to 600 characters is
-- kept, a longer one is refused, and nothing else on app_config moves. Every line prints "<what> (expect X)" and the result.

create or replace function pg_temp.raises(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'NOT raised';
exception when others then
  return 'raised: ' || sqlerrm;
end;
$$;

select '1 the columns exist (expect 2)' as check, count(*) as n from information_schema.columns
  where table_schema = 'public' and table_name = 'app_config' and column_name in ('video_warning_enabled', 'video_warning_text');
select '1 a row from before the migration is ON with no text (expect true, true)' as check, video_warning_enabled as enabled, video_warning_text is null as no_text from public.app_config;

select '2 the switch can be turned off (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set video_warning_enabled = false$$) as result;
select '2 and it reads back (expect false)' as check, video_warning_enabled from public.app_config;
select '2 it cannot be emptied (expect raised)' as check, pg_temp.raises($$update public.app_config set video_warning_enabled = null$$) as result;

select '3 a text is kept (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set video_warning_text = 'Be kind. No abuse.'$$) as result;
select '3 and it reads back (expect Be kind. No abuse.)' as check, video_warning_text from public.app_config;
select '3 exactly 600 characters are accepted (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set video_warning_text = repeat('x', 600)$$) as result;
select '3 601 characters are refused (expect raised)' as check, pg_temp.raises($$update public.app_config set video_warning_text = repeat('x', 601)$$) as result;
select '3 the refused save changed nothing (expect 600)' as check, char_length(video_warning_text) as chars from public.app_config;
select '4 the text can be cleared back to the built-in one (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set video_warning_text = null$$) as result;
select '4 and it is empty (expect true)' as check, video_warning_text is null as is_null from public.app_config;
select '5 the other settings are untouched (expect a brand colour, a font)' as check, brand_color, font_family from public.app_config;
