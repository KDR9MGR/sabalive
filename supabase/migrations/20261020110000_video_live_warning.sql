-- The welcome warning every new arrival sees in their own chat in a video live and in video PK (Application Configuration -> Live welcome):
-- whether it is shown, and its text. Two columns on the existing app_config singleton, so they ride the same world-readable /
-- admin-writable policies and the same Realtime update as the branding colours and the PK look; no new table and no new function.
--
-- Additive only: `video_warning_enabled` has a default (every row, and every old app build, behaves as before: old builds never read it) and
-- `video_warning_text` is nullable (null = the app's built-in, translated text). The check keeps a runaway text out of every phone's chat.
alter table public.app_config
  add column if not exists video_warning_enabled boolean not null default true,
  add column if not exists video_warning_text text;

alter table public.app_config drop constraint if exists app_config_video_warning_text_check;
alter table public.app_config add constraint app_config_video_warning_text_check check (
  video_warning_text is null or char_length(video_warning_text) <= 600
);
