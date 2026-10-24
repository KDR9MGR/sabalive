# sabalive (Flutter consumer app + Supabase backend)

Social live-streaming, audio rooms, PK battles, gifting. Flutter (Dart ^3.11) + Supabase
+ Agora RTC. Also owns the whole database and all Edge Functions.

## Commands
```bash
flutter pub get
flutter analyze        # ~12 pre-existing infos; don't add new ones
flutter test           # keep green
flutter build appbundle   # Play; bump version in pubspec.yaml (+N) per upload
supabase db push       # apply migrations (linked to the project) - LIVE: read docs/DEPLOY_CHECKLIST.md first
supabase functions deploy <name>
scripts/db/replay_migrations.sh      # replay every migration on a throwaway local Postgres
scripts/prod/healthcheck.sh          # read-only: is production healthy?
scripts/prod/smoke_play_app.sh       # replays the Play app's key actions, rolled back
scripts/prod/backup.sh               # data + schema backup to ~/sabalive-backups (before every push)
```
Production is shared with the live Play app: follow "Production safety" in the root CLAUDE.md.

## Layout
- `lib/features/*` screens (live/ has watch_live, watch_audio_room, watch_pk_battle,
  and the host screens), `lib/data/*` repositories, `lib/state/*` controllers
  (provider), `lib/services/*` (agora, permissions, push), `lib/config/*`.
- `supabase/migrations`, `supabase/functions` (agora-token, invite-staff,
  ghost-admin, admin-update-staff-auth, send-push, request-account-deletion).

## Conventions and gotchas
- Presence is table-based, not Agora/Supabase presence: `live_stream_viewers`,
  `join_live_stream`/`leave_live_stream`/`heartbeat_viewer`. Viewers join Agora as
  audience (never announced to others). Channel name = `live_streams.id`.
- Ban/block checks go through `live_access_denied_reason` (SQL) so app, triggers and
  `agora-token` agree.
- Android permissions: no READ_MEDIA_*/storage (Play policy). Photos use
  image_picker's system Photo Picker (`avatar_picker.dart`). Don't re-add them.
- Staff accounts are signed out by `StaffAccountGate`; ghost accounts are normal
  users with `AppUser.isGhost`, and the watch screens hide chat/gift/like/follow/seat
  controls for them (`isGhostViewer`). The server enforces view-only regardless.
- Tests: `test/` is broad; add one next to any logic you change.

## Live room internals (easy to break)
- The live screen is mounted in an overlay Navigator (`ActiveLiveSessionController.navKey`); its
  OverlayEntry must keep `maintainState: true` or anything opened over it tears the live down.
- Open pages from inside a live with `AppNav.open/_push` -> `OverLiveRoute` (sheet); never push a
  MaterialPageRoute directly there.
- System back goes through `_LiveBackInterceptor` -> `ActiveLiveSessionController.handleBack`
  (screens register `backHandler`); don't add `didPopRoute` to live screens.
- `LiveBackGuard` (wraps `_RootGate`) blocks pop on the home route while a full-screen live is up. Without it
  Android 16 (targetSdk 36) lets the system take the back gesture and the user is thrown out of the live
  instead of seeing "leave / end?". Keep it, and keep the live out of the root Navigator's routes.
- Heat / battery: avatar frames animate only at `size >= kAnimatedFrameMinSize`; Realtime bursts on lists are
  coalesced with `CoalescedRunner`; the host clock is a `ValueNotifier` (never `setState` on the whole screen
  from a timer). Don't add looping animations or `ImageFilter.blur` to anything shown during a live
  (the speaking waves are the exception: they run only while someone is talking). Don't mute remote video
  or audio when the app is backgrounded: the product wants the live's audio to keep going.
- Cost control (Supabase meters are multiplied by phones): `live_streams` changes on every heartbeat, join, leave, like and gift and Realtime sends each change to EVERY listener, so
  `LiveStreamsController` reloads at most once per 8 s (`ThrottledRunner`; `CoalescedRunner` still has a 1.5 s window, too short for a table that never stops changing), listens only
  while the app is in the foreground and no live is open full-screen (`setInLiveRoom`), and avatars / card photos are decoded at the size drawn (`ResizeImage`) and kept on the phone after the first download (`DiskCachedNetworkImage`, never plain `NetworkImage` / `Image.network` for user or catalogue pictures). Never subscribe to a
  whole table without a filter in a screen, never poll faster than 20 s without a reason, and prefer one shared timer to one per screen. See `docs/OPTIMIZATION_AND_SUPABASE_2026-10-23.md`.
- Host chat controls live on `live_streams` (`chat_cleared_at`, `pinned_notice`) via `RoomChatState`.
- Live cards and rows carry a type label (`LiveTypeLabel`, `liveKindOf` in `lib/features/live/widgets/live_type_label.dart`): purple mic Audio, pink camera Video, gold bolt PK
  (an old PK-mode live or a live in a battle right now; PK wins over Audio / Video). It replaced the LIVE badge on cards.
- Seat "who is talking": Agora volume -> `SeatSpeaking` using `live_stream_seats.agora_uid`, drawn as the
  `SpeakingWaves` ring. Agora uids are UNSIGNED 32-bit (about half exceed 2^31): store them as bigint, never
  integer, or the RPC fails silently for those users and their seat never lights up.
- Don't run `dart format` on whole directories; it reformats unrelated files.

## PK battles (a layer over audio lives; HANDOFF.md has the plan and the status)
- Server rows in `pk_battles` are the only truth (invited -> accepted -> live -> finished / cancelled). `PkBattleController`
  (`lib/state/`) follows one live's rows through `PkBattlesApi` (the real `PkBattlesRepository`, or a fake in tests), runs the 3 s
  countdown and a timer against the SERVER clock (`pk_now()`), and never decides a score, a winner or a length.
- Everyone in both rooms moves to the Agora channel `pk-<battleId>` while it is live and back after (`PkChannelSwitcher`); the
  `agora-token` function lets the two hosts and the guests on a seat of either room publish there (`battle_access.ts`).
- Switches (panel, Release controls, all default OFF except the fallback): `pk_battles` (audio PK), `pk_video` (video PK: built, off until Agora cost is measured; needs `pk_battles` + `pk_layer`),
  `pk_layer` (default ON; OFF falls back to the old standalone PK screens). Old app builds are never offered as opponents
  (`live_streams.pk_ready`). A Realtime watch must be FILTERED to one live (`watchStream`); never subscribe to every battle.
- Look and controls: audio PK = `PkBattleArena` (`pk_battle_arena.dart`: red / blue halves, up to 7 guest seats a side, the host's Add / Remove seat,
  and End PK); video PK = `PkVideoStage`. End PK = the host gives up (`pk_give_up_v2`: the other host wins). Audio lives and audio PK have NO seat
  requests (owner's decision, 2026-10-21): tap a free seat and sit on it (`claim_seat`); requests are for VIDEO lives only (`request_pk_seat`).
  `request_seat_v2` / `live_streams.seat_requests` stay in the database but no app calls them.
- Look: the owner's SVGA pack is in `assets/pk/` (`tool/pk_assets/README.md`; played by `PkSvga`, never directly) and the panel sets the
  colours and switches through `app_config.pk_theme` -> `PkThemeStore` (`lib/state/pk_theme_store.dart`; fails open; animations off = the plain old
  look). Draw PK colours from `PkThemeStore.instance.theme`, not from `AppColors.live` / `diamond`; the score bar is `PkTugBar` for audio and video.
  Tests that render PK widgets call `usePlainPkLook()` (`test/helpers/pk_fakes.dart`). See `docs/PK_BATTLES.md`.
- Live chat: a new arrival's own chat opens with their "joined" line and a house-rules warning, one for video lives / video PK and one for audio lives / audio PK
  (`arrivalLines`, `LiveWarningStore`, `app_config.video_warning_*` / `audio_warning_*`; the panel sets text and switch under Application Configuration -> Live welcome). Video PK
  also has a gradient behind the stage (`PkVideoBackdrop`, `pk_theme.bg_top` / `bg_bottom`) and a VS between the frames (`PkVideoStage._versus`). An SVGA that plays once and
  then repeats part of itself needs `RemoteMedia(loopFrom:)` (it turns off the player's clear-after-stop). A full-screen paint layer over live video must be `IgnorePointer`
  (`LiveScrim`): a plain `DecoratedBox` swallows taps meant for what is under it.
- New SQL objects are `pk_*_v2` / new names only; `invite_pk_opponent` and the other legacy functions serve the old screens.

## Profile: completion step, fans, staff tags, badges
- **Complete your profile.** After login `ProfileCompletionGate` (`lib/features/auth/profile_completion_screen.dart`, wired in `_RootGate` before the permissions prompt
  and the home screen) asks for date of birth (13+, the picker stops at 13) and country whenever `profiles.date_of_birth` is null. The date of birth is the signal:
  every account starts with country 'India' (a database default), so the country alone can't say who chose one. Ghost accounts are never asked. App-side only (the server
  does not enforce it, so old builds keep working). The country is the English name from `lib/data/countries.dart`, saved in `profiles.location`.
- **Fans = people who follow each other.** `profiles.fans_count` is kept by the extra trigger `follows_fans_after_change` (re-counts both people from `follows`, so it can
  not drift; the old follower trigger is untouched); `get_fans(user)` is the list behind the Fans number (`FollowListScreen(fans: true)`). Migration `20261021180000`.
- **Staff tags** (`profile_tags`, `profile_tag_assignments`, migration `20261021190000`): made and given in the panel (Master -> Tags), written ONLY by the `admin_*_profile_tag` /
  `admin_set_user_tags` functions behind `staff_can_manage_tags()` (Super Admin always, Master by default, any other staff account only with `manage_tags` in its permissions;
  `set_staff_permissions` accepts the key). They are not the Store's VIP tags. The app reads them with the earned badges in `ProfileLabelsRepository` and draws both with
  `ProfileLabelsRow` on both profile screens only (badges first, then tags; not in chat); every read fails open to "nothing to show". A tag has one of three looks
  (`profile_tags.look`): `pill` (name on a colour), `picture` (an uploaded banner shown as it is, the name is inside the artwork) or `plate` (an uploaded background with the
  name written on it, `text_color`); a picture that can't load falls back to the pill. A badge with an uploaded picture is the picture itself (a banner, 26 px tall); animated
  files and badges without a picture are the emoji chip.
- **Level pictures instead of stars** (`LevelImageStore`, `LevelPicture` in `lib/core/widgets/level_star.dart`): the picture the panel's Levels page holds for a level
  (`track_levels.image_url`, the same file as the join banner) replaces the star for people at EXACTLY that level (no borrowing from a lower level) on profiles, in live chat
  and in the join notice. The number is part of the picture. Only still / GIF / WebP files count: SVGA and MP4 keep the star (a looping animation per chat line costs battery).
  Pictures are kept on the phone by `EffectFileCache` (each downloaded once) and decoded small; the star shows until the picture is ready or if it fails.

## Translations (9 languages)
- Every screen imports `package:flutter/material.dart' hide Text;` plus `core/i18n/text.dart`, whose `Text`
  translates its English string at build time. Hints / tooltips use `tr('...')`. English in code is the key.
- Add or change strings through `tool/i18n/` (see its README): `keys.json` + `tr_<lang>.tsv` -> `gen.py` writes
  `lib/core/i18n/strings_*.dart`. Never hand-edit those. `missing.py` lists untranslated candidates.
- New screens must use that `Text` (copy the two imports from any other screen) or they stay English.
- Language switch = `I18n.set(...)`: persists, flips MaterialApp's locale (RTL for Arabic/Urdu) and
  marks every element dirty so nothing loses its state.
- Audio: Agora scenario is game-streaming (media volume) so MP4 gift sound and music are audible; local
  songs use the system file picker (no storage permission) + Agora audio mixing (`LocalMusicController`).

## Bans (device / account / identity / IP)
- An account or device ban (`user_bans`) also writes to `banned_identities` (normalized email / phone / Google / Apple id; gmail
  dots, `+tag` and `googlemail` are folded) and `banned_ips` (24 h, new accounts only, skipped for IPs seen with 4+ accounts). These
  outlive the account (`user_bans.user_id` is `on delete set null`), and a lift releases them (`release_ban_signals`).
- Enforcement: BEFORE INSERT triggers on `auth.users` / `auth.identities` refuse a banned identity with SQLSTATE `BN010` for
  ANY client, old or modified. They fail open on internal errors: a bug must never stop honest sign-ups. Keep them that way.
- The app calls `check_signup_access` (anon-callable) before sign-in / sign-up with every device id and falls back to
  `check_device_access` on an older server. `register_device_v2` stores a second Android id (`drm:` Widevine hardware id, survives a
  factory reset) and spreads a ban to all of a user's ids. The Kotlin `device_ids` channel is a thin wrapper: no id = no extra id.
- The sign-up IP is only visible to the `before_user_created_hook` Auth hook (Dashboard -> Authentication -> Hooks), which is
  inert until the owner enables it. MAC addresses are unreadable on modern Android / iOS: never promise a MAC ban.
- Retiring old app versions = the minimum Android version code in Master -> Config -> Release controls (owner's release decision).
- Staff see "Linked accounts" on a user's profile (`admin_linked_accounts`: same phone / network / login).
