-- PK look, set from the admin panel (PK Battles -> Look and colours): the colour of each side, an accent, whether the PK
-- animations play, an optional full-screen intro, and the style of the "lose" badge. One small JSON object on the existing
-- app_config singleton, so it rides the same world-readable / admin-writable policies and the same Realtime update as the
-- branding colours; no new table and no new function.
--
-- Additive only: a nullable column, so every existing row and every app build is unchanged (an app that does not know the
-- column never reads it; the new app uses its built-in look while the value is null). The check refuses malformed values so a
-- bad save from anywhere can never put garbage in front of the apps:
--   {"mine": "#ff2d55", "theirs": "#2d6bff", "accent": "#ffc93c", "animations": true, "hero_intro": false, "lose_style": "shield"}
-- Every key is optional; an absent key keeps the app's default.
-- app_config is read by every phone at launch and resume: never wait long for its lock
set local lock_timeout = '5s';

alter table public.app_config
  add column if not exists pk_theme jsonb;

alter table public.app_config drop constraint if exists app_config_pk_theme_check;
alter table public.app_config add constraint app_config_pk_theme_check check (
  pk_theme is null or (
    jsonb_typeof(pk_theme) = 'object'
    and (pk_theme -> 'mine' is null or pk_theme ->> 'mine' ~ '^#[0-9a-fA-F]{6}$')
    and (pk_theme -> 'theirs' is null or pk_theme ->> 'theirs' ~ '^#[0-9a-fA-F]{6}$')
    and (pk_theme -> 'accent' is null or pk_theme ->> 'accent' ~ '^#[0-9a-fA-F]{6}$')
    and (pk_theme -> 'animations' is null or jsonb_typeof(pk_theme -> 'animations') = 'boolean')
    and (pk_theme -> 'hero_intro' is null or jsonb_typeof(pk_theme -> 'hero_intro') = 'boolean')
    and (pk_theme -> 'lose_style' is null or pk_theme ->> 'lose_style' in ('shield', 'emoji'))
  )
);
