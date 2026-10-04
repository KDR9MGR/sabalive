# sabalive (Flutter consumer app + Supabase backend)

Social live-streaming, audio rooms, PK battles, gifting. Flutter (Dart ^3.11) + Supabase
+ Agora RTC. Also owns the whole database and all Edge Functions.

## Commands
```bash
flutter pub get
flutter analyze        # ~12 pre-existing infos; don't add new ones
flutter test           # keep green
flutter build appbundle   # Play; bump version in pubspec.yaml (+N) per upload
supabase db push       # apply migrations (linked to the project)
supabase functions deploy <name>
```

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
- Host chat controls live on `live_streams` (`chat_cleared_at`, `pinned_notice`) via `RoomChatState`.
- Seat "who is talking": Agora volume -> `SeatSpeaking` using `live_stream_seats.agora_uid`.
- Don't run `dart format` on whole directories; it reformats unrelated files.
