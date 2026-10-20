-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/pk_theme_test.sql
-- Proves the PK look column (migration 20261020100000): it starts empty, takes a full or a partial object, and refuses anything
-- malformed. Every line prints "<what> (expect X)" and the result: compare them by eye (or grep for 'expect').

create or replace function pg_temp.raises(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'NOT raised';
exception when others then
  return 'raised: ' || sqlerrm;
end;
$$;

select '1 the column exists and starts empty (expect 1, true)' as check,
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'app_config' and column_name = 'pk_theme') as columns,
  (select pk_theme is null from public.app_config) as empty;

select '2 a full object is accepted (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"mine":"#ff2d55","theirs":"#2D6BFF","accent":"#ffc93c","animations":true,"hero_intro":false,"lose_style":"shield"}'$$) as result;
select '2 and it reads back (expect shield, #2D6BFF)' as check, pk_theme ->> 'lose_style' as lose_style, pk_theme ->> 'theirs' as theirs from public.app_config;

select '3 a partial object is accepted (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"mine":"#00ff00"}'$$) as result;
select '3 and it reads back (expect {"mine": "#00ff00"})' as check, pk_theme from public.app_config;

select '4 an empty object is accepted (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{}'$$) as result;
select '4 and it reads back (expect {})' as check, pk_theme from public.app_config;

select '5 a list is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '[1,2]'$$) as result;
select '5 a bare string is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '"red"'$$) as result;
select '5 a colour name is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"mine":"red"}'$$) as result;
select '5 a short hex is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"theirs":"#12345"}'$$) as result;
select '5 a hex with no hash is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"accent":"ffc93c"}'$$) as result;
select '5 a non-hex digit is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"mine":"#gg0000"}'$$) as result;
select '5 animations as text is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"animations":"yes"}'$$) as result;
select '5 hero_intro as a number is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"hero_intro":1}'$$) as result;
select '5 an unknown lose style is refused (expect raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"lose_style":"sad"}'$$) as result;
select '5 the emoji style is accepted (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = '{"lose_style":"emoji"}'$$) as result;

select '6 the refused saves changed nothing (expect emoji)' as check, pk_theme ->> 'lose_style' as lose_style from public.app_config;
select '7 it can be cleared again (expect NOT raised)' as check, pg_temp.raises($$update public.app_config set pk_theme = null$$) as result;
select '7 and it is empty (expect true)' as check, pk_theme is null as empty from public.app_config;
select '8 the other settings are untouched (expect a brand colour, a font)' as check, brand_color, font_family from public.app_config;
