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
- Host chat controls live on `live_streams` (`chat_cleared_at`, `pinned_notice`) via `RoomChatState`.
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
- Switches (panel, Release controls, all default OFF except the fallback): `pk_battles` (audio PK), `pk_video` (video PK, not built),
  `pk_layer` (default ON; OFF falls back to the old standalone PK screens). Old app builds are never offered as opponents
  (`live_streams.pk_ready`). A Realtime watch must be FILTERED to one live (`watchStream`); never subscribe to every battle.
- New SQL objects are `pk_*_v2` / new names only; `invite_pk_opponent` and the other legacy functions serve the old screens.

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
