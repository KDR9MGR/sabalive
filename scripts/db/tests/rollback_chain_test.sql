-- Run with: scripts/db/replay_migrations.sh scripts/db/tests/rollback_chain_test.sql
-- Proves: every pending migration's down script runs cleanly, newest first, on a database that has all migrations (ERROR lines = a rollback that would fail when it is needed).
\set ON_ERROR_STOP off
select 'before: moderation tables / functions / emotes' as step,
  (select count(*) from pg_class where relname in ('live_room_admins','live_stream_kicks','live_chat_mutes')) as tables,
  (select count(*) from pg_proc where proname in ('set_room_admin','kick_viewer','mute_chat','send_gift_to_all','admin_remove_user_badge')) as funcs,
  (select count(*) from public.live_emojis) as emotes,
  (select count(*) from pg_proc where proname in ('start_game_session','game_apply_balance','game_get_user')) as game_funcs;
\i supabase/rollbacks/20261013140000_tulasi_game_curation_down.sql
\i supabase/rollbacks/20261013130000_tulasi_games_realtime_down.sql
\i supabase/rollbacks/20261013120000_tulasi_game_monitoring_down.sql
\i supabase/rollbacks/20261013110000_tulasi_game_list_down.sql
\i supabase/rollbacks/20261013100000_tulasi_games_down.sql
\i supabase/rollbacks/20261012110000_more_live_emotes_down.sql
\i supabase/rollbacks/20261012100000_down.sql
\i supabase/rollbacks/20261010100000_live_moderation_admins_down.sql
\i supabase/rollbacks/20261010090000_lucky_box_cooldown_down.sql
\i supabase/rollbacks/20261009140000_app_config_realtime_down.sql
\i supabase/rollbacks/20261009120000_effect_speed_and_sound_down.sql
\i supabase/rollbacks/20261009110000_send_gift_to_all_down.sql
\i supabase/rollbacks/20261009100000_instant_leave_and_faster_sweep_down.sql
\i supabase/rollbacks/20261009090000_push_function_url_from_vault_down.sql
select 'after: all rolled back' as step,
  (select count(*) from pg_class where relname in ('live_room_admins','live_stream_kicks','live_chat_mutes')) as tables,
  (select count(*) from pg_proc where proname in ('set_room_admin','kick_viewer','mute_chat','send_gift_to_all','admin_remove_user_badge')) as funcs,
  (select count(*) from public.live_emojis) as emotes,
  (select count(*) from information_schema.columns where table_name in ('gifts','store_items') and column_name in ('play_speed','sound_url')) as effect_cols,
  (select count(*) from information_schema.columns where table_name='lucky_box_config' and column_name='cooldown_hours') as cooldown_col,
  (select count(*) from information_schema.columns where table_name='live_chat_messages' and column_name='to_all') as to_all_col,
  (select count(*) from pg_proc where proname in ('start_game_session','game_apply_balance','game_get_user')) as game_funcs,
  (select pg_get_constraintdef(oid) like '%game_bet%' from pg_constraint where conname='wallet_ledger_kind_check' and conrelid='public.wallet_ledger'::regclass) as game_kinds_left;
