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
  name written on it, `text_color`); a picture that can't load falls back to the pill. A badge with an uploaded picture is the picture itself (a banner, 26 px tall); badges without a
  picture are the emoji chip. Tag and badge pictures are drawn by `LabelPicture` (`lib/core/widgets/label_picture.dart`): stills, GIF and WebP through the disk-cached image, **SVGA played
  scaled to the height** (the panel accepts `.svga` for tags and badges, owner 2026-10-25); the pill / emoji chip stands in while an SVGA loads or if it fails or is empty; a video file
  (MP4) is never drawn on a profile, the pill / chip is shown. The Badges screen (`badges_screen.dart`) draws the same uploaded `icon_url` instead of the emoji.
  The small Store pills under the name (VIP / frame names, `EquippedCosmetics`) were removed from both profile screens on 2026-10-25 (owner: "get rid of store tags"); staff tags and badges stay.
- **Level pictures instead of stars** (`LevelImageStore`, `LevelPicture` in `lib/core/widgets/level_star.dart`): the picture the panel's Levels page holds for a level
  (`track_levels.image_url`, the same file as the join banner) replaces the star for people at EXACTLY that level (no borrowing from a lower level) on profiles, in live chat
  and in the join notice. The number is part of the picture. Only still / GIF / WebP files count: SVGA and MP4 keep the star (a looping animation per chat line costs battery).
  Pictures are kept on the phone by `EffectFileCache` (each downloaded once) and decoded small; the star shows until the picture is ready or if it fails.
- **Levels are the panel's numbers.** Wealth and Charm each have their OWN XP per level in `track_levels` (Master -> Levels edits it and re-levels everyone). The My Level screen
  (`my_level_screen.dart`) reads exactly that through `LevelsRepository` (`level_thresholds` is only the fallback when `track_levels` can't be read; it also feeds the old combined
  "LV X" badge, which the panel does not edit). The panel gives every level EXACTLY the XP typed, with no relation to the level before or after it (`admin_save_track_level_v3`, migration `20261025140000`; the strict v1 and the shifting v2 stay but the
  panel only falls back to them): a person is at the HIGHEST level whose XP they reached, so out-of-order numbers are allowed (My Level shows a level unlocked only when it is theirs or they reached its XP). Fixed rules:
  level 1 needs 0 XP, the next new level is highest + 1, XP is a whole number up to 2,147,483,647 (integer column). v2's shift stopped at 2,000,000,000 and production's Wealth ladder ends exactly there, so Wealth edits
  needing a shift always failed while Charm worked. Level pictures are cached 5 minutes
  (`LevelBannerImages` + `LevelImageStore`), so a picture changed in the panel shows within a few minutes in chat and on profiles. **My Level** (2026-10-26) shows each level's picture in its card (dimmed with a lock until reached, the
  medal when the panel set none or while it loads; the header shows the picture of the person's level) in a lazy grid, and stays in step with the panel: it reads when it opens, every 20 s while open and the app is in front
  (`kMyLevelRefresh`; `track_levels` is not in the Realtime publication, so it polls), when the app returns to the front and on a pull down (the last two and the opening also force the pictures:
  `LevelImageStore.refresh()` / `LevelBannerImages.invalidate()`), redraws only when something changed (value equality on `MyLevel`), and keeps what is on screen if a read fails. **My Profile's level stars** come from `AuthController.user` (the profile read at sign-in), so they used to stay stale until a restart: while the Profile tab is the selected one and the app is in front, `RefreshWhileVisible`
  (`lib/core/widgets/refresh_while_visible.dart`, `active:` from `SessionController.tab == kProfileTab`; an IndexedStack keeps hidden tabs' tickers running, so Flutter's own visibility cannot be used) calls `AuthController.refreshLevels()` when the tab
  opens, on resume and every 30 s (two small columns of one row), and My Level hands every read to `AuthController.applyLevels`, so the two screens never disagree. Check a whole project with `scripts/prod/check_levels.sh` (read-only, counts only: ladder gaps, wrong levels, XP versus gift coins; `SUPABASE_WORKDIR=...` for staging).

## Gifts: quantity (1x / 10x), Send to All, who hears the sound (2026-10-25, migration `20261025100000_gift_quantity_and_receivers`)
- One tap on 10x is ONE call and ONE chat line, not ten: `send_gift_v2(gift, receiver, stream, quantity)` and `send_gift_to_all_v2(gift, stream, quantity)` (quantity 1..99, balance checked up front for
  price x quantity x people, one wallet / gift_transactions row per unit, one `live_chat_messages` row). The chat line says `sent Alice 10x Rose` (the `Nx` only when the quantity is above 1) or
  `sent 10x Rose to 5 people` for Send to All (always with the count of people and the `Nx`); the row also carries `gift_count` and `gift_receiver_ids`. The app calls them through `GiftSender`
  (`lib/data/gift_sender.dart`, used by `WalletController.sendGift` / `sendGiftToAll`) and falls back to the old `send_gift` / `send_gift_to_all` (one call per unit) when the v2 functions are missing
  (PGRST202 / 42883), so a new app works on a database that does not have the migration yet. Old functions stay for old Play builds.
- Sound rule (`RoomEffectController.onChatRow` in `room_effect.dart`): the gift's SOUND plays on the phones of the people it was sent to, AND on the sender's own phone unless the sender's microphone is open (`senderHearsOwnGift(micOpen:)`: the host, or
  someone on a seat; changed 2026-10-28: before, a viewer who sent an MP4 gift with sound heard nothing at all). Everyone else sees it silently. The sender's own effect is created with
  `playSound: senderHearsOwnGift(...)` (the picture and the animation always play) and a chat row whose `gift_receiver_ids` does not contain me is shown silently. A row WITHOUT `gift_receiver_ids` (an old app's gift)
  plays for everyone as before, because the receivers are unknown. Send to All lists everyone except the sender. A new gift entry point must go through `GiftSender` and pass `playSound: false` for the sender's own effect.

## Share and invite links
- The invite link is `https://sabalive.in/invite/<CODE>` (`inviteShareUrl(code)` in `lib/core/utils/share_links.dart`; also the QR code on the invite screen). It is a page of OUR site
  (`sabaliveadmin/landing/src/pages/Invite.jsx`, pure rules in `landing/src/lib/invite.js`, tested) that looks at the phone: **Android** goes straight to the Google Play listing with the code as the Play
  "referrer" (`utm_source=invite&utm_medium=referral&utm_content=<CODE>`), an **iPhone** is told the iPhone app is coming soon (the App Store link goes in `STORE_LINKS.ios` in `landing/src/lib/site.js`; once set,
  iPhones are redirected there), a computer sees both. The page also shows the code with a Copy button, because the friend still types it in the app (reading the Play referrer on first launch would need the
  Install Referrer plugin and a Play build: not done). Before 2026-10-26 the link was the Play URL itself (no use on an iPhone), and before that `sabalive.app/invite/<code>`, which never existed. The app's App Links
  claim only `/live/`, so `/invite/...` always opens in the browser. **The page must be live on sabalive.in (the panel/landing repo deployed) before a build that uses the new link is shared**, or the link shows the site's
  "not found" page. The public site's `STORE_LINKS.android` points at the same listing.

## Who reports to whom (Global > Country > Sub > Agency)
`agencies.sub_admin_id` -> the Sub Admin; `staff_roles.country_admin_id` (on a sub admin) -> the Country Admin; `staff_roles.global_admin_id` (on a country admin) -> the Global Admin (migration `20261026100000`:
the column did not exist before, so every Global Admin column in the Salary exports was empty). It is a REPORTING link only: RLS still lets every Global Admin see the whole tree. Back-filled from the audit log (the creator of a
Country Admin, if that creator is a Global Admin); set automatically when a Global Admin creates a Country Admin (trigger on the `staff.created` audit row, `create_staff_account` untouched); assigned or moved with
`transfer_country_admin(country_admin, to_global_admin)` (Master / Super Admin any, a Global Admin only their own) from the panel's Transfer Global page. `salary_agency_map()` reads it, so the exports and tables show
Sub / Country / Global Admin each with name + app User ID ("Not assigned" when the system has none). Check coverage with `scripts/staging/verify_global_link.sh`.

## Games: Tulasi and SUD (two providers, one panel in the app)
Tulasi games (`merchant_games`, a game URL in a WebView) are described in `docs/TULASI_GAMES.md`. **SUD games** (`docs/SUD_GAMES.md`) are a second provider: they run in SUD's NATIVE Android / iOS SDK (`sud_gip_plugin`, `lib/features/games/sud_game_screen.dart`) inside the same bottom game panel (2026-10-28: SUD's web SDK answered error 10005 for every game and SUD said the games are for Android and iOS, so the first design, a page of ours with the web SDK at `/sud/play`, is no longer used). Rules that keep the two apart: SUD games live in their own table `sud_games` (old apps never see them and Tulasi's
Sync cannot switch them off), internal ids start at 1,000,000, the SUD game id is TEXT, the app launches through the `sud` Edge Function (`sud/launch`, deployed `--no-verify-jwt`; it verifies the user and
SUD's HMAC-SHA1 signed callbacks itself), and two switches default OFF (`sud_games_enabled`, `sud_coin_games_enabled`; both need `games_enabled`). Coin games reuse `game_config`, `game_transactions` and the
`game_bet` / `game_win` ledger kinds (`sud_apply_score`). Secrets `SUD_APP_ID`, `SUD_APP_KEY`, `SUD_APP_SECRET` are set by the owner, never by an assistant or in chat. Staging check: `scripts/staging/verify_sud_games.sh`.
**Tulasi game panel size** (`game_panel.dart`, `game_webview_screen.dart`, owner 2026-10-29: "each game has a different size and some are cut off, e.g. Monkey Pro"): the panel follows what the game asks for. `parseDesignAspect` now trusts the engine's design size whatever scaling rule the game uses
(it used to believe only `FixedWidth` and kept a guess for the rest, which cut off a game that scales another way): height / width of the design is the panel that shows all of it with nothing cut off or empty. The run-time size is not always the truth: Monkey Pro (`greedyMonkey`) says 750 x 750 while running but its own settings (and its layout) are 750 x 902, so the measuring script also reads `cc.settings.querySettings('screen','designResolution')` and the TALLER of the two wins (the engine template 750 x 1334 in the settings is ignored: it means nobody set a size). A game that never gives a readable size for 12 s gets the biggest panel
the screen allows at full width (`shouldFillPanel`, `gameFillAspect`); the engine's own 750 x 1334 starting size still counts as talking, so a game that really is that size does not jump. Public game files can be read for a design size without a login (Cocos 3 games: `<domain>/<id>/<version>/src/settings.*.json` > `screen.designResolution`; the runtime value can differ, e.g. Lucky99 is square at run time).
**Game panel close button** (`lib/features/games/game_panel.dart`, owner 2026-10-26): the round X sits in its own row ABOVE the panel (`kGameCloseRow`, right-aligned, outside the game, in the dimmed room above it), no longer floating over the game's top right where it
covered the game's own controls. The panel is at most the screen minus the status bar and that row (`gamePanelHeight(topInset:)`); a very tall game on a short phone is narrowed at its own proportions rather than cropped.

**Games tab sort and filter** (2026-10-28, built, not shipped; migration `20261028100000_games_sorting.sql`): chips All / Coin games / Party games (only when both kinds exist; `MerchantGame.stakesCoins`) and a Sort by sheet
(Top picks = the platform's order and the default, Most played, Newest first, Oldest first, A to Z), remembered in `games.sort.v1` / `games.kind.v1`. The ordering is pure code in `lib/features/games/games_sort.dart` (stable; ties keep the platform's order).
Server side everything is additive: `added_at` on `merchant_games` / `sud_games`, the `game_plays` log written ONLY by `record_game_play` (the launcher calls it after the server accepted a launch; ghosts, hidden / off games and a repeat within 60 s are ignored) and the tiny
`game_popularity` table that pg_cron `refresh-game-popularity` rebuilds every 15 minutes from the last 14 days, so the app never counts the log. `GamesStore` reads popularity at most every 5 minutes. On a database without the migration the sorts that need
it simply keep the platform's order. Don't make the app read `game_plays` (it has no policy on purpose) and don't shorten the cron below a few minutes (60 connections).

## Monthly diamond reset (2026-10-26, built, not shipped: `docs/DIAMOND_RESET.md`)
Master / Super Admin (never a lower role, even with Run payroll) clear a FINISHED month's gift diamonds, Lucky Box reward diamonds, or both from the wallets that still hold them (panel: Economy -> Diamond Reset).
`admin_diamond_reset_preview` / `admin_reset_diamonds(month, 'gift'|'reward'|'both', typed month)` / `admin_undo_diamond_reset` (migration `20261026120000`); the amounts come from ONE function (`_diamond_reset_plan`): the
month's credits, capped by the balance minus positive credits that arrived after the month (withdrawals use the oldest diamonds first). Each (month, kind) once; each wallet gets one negative `grant_reversal` ledger row
(`reference_table = 'diamond_reset_runs'`), which the Salary reports do not count, so only the wallet balance changes. Hosts get the standard "reclaimed by an admin" notification. **Automatic version** (migration `20261026130000`): `diamond_reset_settings` (switch OFF by default, gifting / reward checkboxes, run day 1-28) set with
`admin_set_diamond_reset_auto`; the pg_cron job `diamond-reset-auto` (18:35 UTC = 00:05 India time daily) calls `run_diamond_reset_auto()`, which acts only on the chosen day and resets the PREVIOUS month through the same `_diamond_reset_run_one` the
buttons use (runs have `auto = true`, no person; no catch-up if a day is missed). Check: `scripts/staging/verify_diamond_reset.sh`.

## Quick-fix batch of 2026-10-26 (owner's list of nine; migration `20261026140000`)
- **Profile labels.** `ProfileLabelsRow` (`lib/features/profile/widgets/profile_labels.dart`) draws badges first, then staff tags. Sizes are `LabelSizes.profile` (badge pictures 34, tags 28, chip text 12.5) or `LabelSizes.compact`
  (22 / 20 / 10) for a ONE-LINE row in a list (`compact: true`, at most 3, clipped never wrapped). A **plate** tag is exactly as big as its ARTWORK at the tag height (2026-10-26: `LabelPicture` reads the real proportions of an SVGA / SVG, the whole picture is shown, never cropped or stretched) with the name
  centred on it, shrinking to fit; a name with no letter or digit (".", "-") is not written at all (`TagPill.nameIsWritten`: the owner's single tag is named "." because its SVGA already carries the text). Until the
  artwork is read, or if it fails, a coloured capsule with room for the name stands in (the name is written once). It used to be sized by the NAME, which cut a "." tag's artwork to a tiny box ("Hos"). `LabelPicture` clips an SVGA to its own box (`ClipRect`): the player draws outside its canvas by default, and the owner's Host tag has a 500 px light-sweep layer on a 310 px canvas, which showed as a grey strip beside the tag every time it played. The Store's own items are never drawn on a profile; the dead "VIP · Luxury Privileges" banner on My Profile was removed (it opened "coming soon").
  Lists of people (followers / following / fans, search, profile visitors, rankings) show the compact row under the name through `PersonLine`, and the live-room user card (`user_actions_sheet.dart`) shows the full row. They read
  through `ProfileLabelsCache` (`profile_labels_repository.dart`): asks made in the same moment become ONE `loadMany` (two database reads in all), answers kept 5 minutes, pieces of 60. Not in chat lines (a read per line).
- **SVG** (plain vector drawings, not SVGA) are a media kind of their own: `MediaKind.svg`, drawn by `RemoteMedia` (`_SvgMedia`, `flutter_svg`, read once and kept on the phone), `LabelPicture`, `LevelPicture` and still effects. The panel
  sends an .svg as `application/octet-stream` (like SVGA) so no storage bucket type list had to change; a broken file shows the fallback. `RemoteMedia` now shows its `fallback` until a still picture's first frame is decoded.
- **Gift sheet.** Tabs: Popular, New, Effects, then a tab for every panel category that has gifts (Basic, Luxury, Vehicle, Special, Event: `giftTabsFor`); the tab row scrolls. **Send to All includes the sender** when they are the host or on
  a seat: `send_gift_to_all_v3` (v2 stays for old builds; `GiftSender.sendToAll` tries v3, then v2, then the old ones); the "All" count is every person in the sheet (`giftSendAllPeople`). A gift tile shows a quiet shape (not the emoji)
  while its artwork loads, the emoji only if there is none or it fails (an MP4 tile keeps the emoji: only a few video stills are held at once). `GiftArtworkWarmer` (`lib/core/media/`) puts the first 60 gifts' files on the phone, two at a
  time, when a live opens (`WalletController.refreshCatalog`), NOT at app start (egress). SVGA files go to flutter_svga's own disk cache (raw bytes, no decode).
- **iOS coin sellers.** `FeatureFlags.coinSellerVisible`: Android always; iOS follows the panel's Release control `coin_seller_ios` (default OFF since 2026-10-27, see "Apple App Store review" below); the wallet screen's "Buy from Offline Seller" button listens to it.
- **Diamond reset is a permission**: `reset_diamonds` (Access Control, on by default for a Master, never for a lower role; `_diamond_reset_actor_ok()` reads it). See `docs/DIAMOND_RESET.md`.

## Apple App Store review (iOS) (2026-10-27; Apple's message about version 1.0 (2) of 2026-09-19)
iOS has never been published. Apple's message (4.1(a) copycat, 5.2.1 China live-streaming licence, 2.1(a) iPad bugs, 2.3.6 age rating x2) and what was done in code; the rest is the owner's (App Store Connect, artwork, licences):
- **Rules that apply on iOS only** (`FeatureFlags`, with `isIOSOverride` for tests; Android unchanged): `comingSoonVisible` / `gamesEntryVisible` / `buyCoinsVisible` are false on iOS. Hidden there: Room Effects and Family in the Profile menu, Request Withdrawal, Funny voice,
  "Invite someone" on a seat, the Mobile tab of Forgot Password, the Games tab / tools / strip, Invite PK / Random PK unless PK really works (`pkToolsVisible`), Buy Coins and every "top up" prompt (no In-App Purchase yet; Apple 3.1.1). `coin_seller_ios` now
  defaults to OFF (an offline seller buys coins outside In-App Purchase); the panel's switch (Super Admin, Application Config -> Release Settings -> "Coin sellers on iOS" -> Save release controls) turns it ON. Test: `test/ios_review_rules_test.dart`.
- **Device and orientation**: the iOS target is iPhone only (`TARGETED_DEVICE_FAMILY = 1`) and portrait only (Info.plist), so the app is not reviewed in an iPad layout (the iPad review is where the unresponsive chat / live reports came from; the cause was never
  reproduced: it needs a signed-in run on a real device). Camera / microphone permission wiring (Podfile `PERMISSION_*` flags, usage strings) was checked and is fine.
- **Google sign-in crashed the whole app on iOS** (found by running the app in the iPhone simulator): the native plugin needs `GIDClientID` in Info.plist, which does not exist (the Firebase file has no CLIENT_ID), and its missing configuration is a native exception Dart cannot catch.
  `GoogleConfig.nativeSignInSupported(isIOS:)` makes iOS use the browser sign-in (the one Apple uses; it works: opens accounts.google.com in the in-app Safari view). To bring the native picker back: create the iOS OAuth client in Google Cloud, add its id as `GIDClientID` and the reversed id as a URL scheme.
- **"alpha" wording** is gone: Settings shows the real version (`PackageInfo`), the Help text no longer says "during the alpha" (translations updated).
- **Building for iOS**: `flutter build ios --simulator` fails under Xcode 27 / Flutter 3.41.5 at `debug_unpack_ios` ("does not contain architectures arm64 x86_64" although lipo lists both). Workaround that works: `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ONLY_ACTIVE_ARCH=YES ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build`,
  then ad-hoc sign every `Frameworks/*.framework` and the app (`codesign --force --sign -`) or the simulator refuses to load Agora. The app launches, onboarding and login work on an iPhone 17 simulator (iOS 27).
- **Still open (owner)**: Age Rating "Messaging and Chat" = Yes and "User-Generated Content" = Yes (App Store Connect); China mainland removed from availability + a reply that the app is for India (5.2.1); the icon and splash artwork carry a red "play button + LIVE" pill (and a small red play button inside the S) that looks like YouTube's (4.1(a)): needs new artwork (an automatic fill of the pill looked wrong,
  so the icon was NOT changed); check the App Store name / description / screenshots for lookalike content; a demo login for App Review and a live running during review; test the new build on a real iPhone and iPad.

## Keeping old and modified copies out (plan: `docs/PLAY_INTEGRITY_PLAN.md`)
Only the minimum-version gate exists (panel: Application Config -> Release Settings -> Android minimum version code). Set it only AFTER the new version is live on Play at 100%, or everyone is locked out. It cannot block builds from before 2026-10-06 (no gate in them), nor a
modified copy (the check runs inside the app). The plan (server-side build check, Play Integrity verified by an Edge Function in shadow mode first, enforced only on coin-moving actions, plus an audit of the server rules) is written down, not built.

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
- Ban length and reason (2026-10-25, migration `20261025120000`): `ban_user_v2(user, kinds, duration, reason, ends_at)` adds `24h` and `custom` (an end date 5 minutes to 10 years ahead) to `7d` / `30d` /
  `permanent`; presets are worked out on the SERVER clock. `ban_user` stays (`set_profile_status` calls it). A reason typed through v2 is marked `user_bans.reason_visible` and is SHOWN to the banned
  person; a reason of any older ban (or a v1 ban) is a staff-only note and is never shown. Before sign-in the app asks `check_login_access_v2(device ids, email, phone)` (callable by anon) which finds an
  ID-banned account by its email / phone, a banned phone or a blocked identity, and returns the end time and the visible reason; `AuthController.signupBlockedMessage` writes "Your account is banned until
  27 Oct 2026, 14:30." plus a second line "Reason: ...", already translated (`tr`), and the login screen keeps it as the red notice banner (no duplicate snackbar). A database without the v2 function falls back to
  `check_signup_access`. Ban ends are shown with their time (`formatBanDate`). The reason is readable by anyone who types the banned email on the login screen, so the panel tells staff to write it for the user.
