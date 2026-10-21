# PK battles (PK as a layer over audio and video lives)

A PK battle is a timed contest between two hosts of the SAME kind (audio vs audio, video vs video). Viewers of either room gift either side;
the score is the coins of those gifts; the higher score wins at 00:00. It is a layer over an ordinary live, not a separate screen, so the
room keeps its chat, gifts, entry banners, Leave / Minimize, seats and moderation.

## Switches (Application Configuration -> Release controls, Super Admin; all default OFF except the fallback)
| Switch | Effect |
|---|---|
| `pk_battles` | Audio PK for players on a build that has it. Off: PK says "coming soon". |
| `pk_layer` (default ON) | Off = Go Live -> PK opens the OLD standalone PK screen (emergency fallback). Counts only while `pk_battles` is on. |
| `pk_video` | Video PK (two cameras side by side). Needs the two above. Keep OFF until Agora cost is measured. |
The panel's **PK Battles** page (`/admin/pk`) shows the switches, the rules, daily totals and every recent battle.

## How a battle goes
1. A host goes live (Go Live -> PK -> Audio PK / Video PK, or any live and Tools -> Invite PK / Random PK).
2. **Invite PK**: pick 5 / 10 / 30 / 40 min and a host they follow who is live now and free. **Random PK**: both hosts search; a pair
   starts at once and lasts 5 min. An invited host Accepts or Declines.
3. 3-2-1, then the battle runs. Everybody in both rooms moves to the Agora channel `pk-<battleId>` (guests on a seat keep talking in an
   audio battle; in a video battle they only listen). Audio: the old PK look inside the live room: a red half (this room) and a blue half (the other room), each with the host's big picture, name and up to 4 guest seats (people first, then the lowest free seats; the other room's half is read-only), and the tug-of-war bar, VS badge, clock and scores under it; the room's own seat grid and Add / Remove 4 wait until the battle ends. Video: scores and clock over a slim red / blue bar, then the two videos in red and blue frames, WIN on the leader and LOSE on the other.
4. At 00:00 a host's phone (or the server within a minute) finishes it: result dialog, everybody returns to their own channel.
5. A host who ends the live or is silent for 60 s loses (forfeit); the other host wins.

## What the host and the viewers can do during an AUDIO battle
- **Gifts**: the normal gift sheet; the other host is one more person in its list (a gift to either host counts for that host's side, no
  extra question), a gift to a guest is an ordinary gift, "send to all" never includes the other host.
- **Seats**: each half shows up to 7 guest seats. The host has Add seat / Remove seat (one at a time, 4 to 8 seats in total; the normal
  Add 4 / Remove 4 come back after the battle), can lock only the seats of their own room (the other half is read-only) and sees Requests.
- **Seat requests** (audio rooms, in a battle and outside one): a viewer who taps a free seat asks the host (`request_seat_v2`) when the room is in a
  battle or the host has "Ask before someone sits" on (`live_streams.seat_requests`; a new audio room starts with it ON, the host switches it in
  the Requests list, and the Requests button sits next to Add 4 / Remove 4). The host accepts or declines (`approve_pk_seat_request`, which already
  worked for any live); open requests are closed when asking stops (`clear_seat_requests_v2`). It is a courtesy, not a lock: `claim_seat` is
  unchanged, so app builds that do not know the setting still sit at once. A server without migration `20261019100000` makes the app fall back
  to taking the seat at once (and hides the setting).
- **End PK** = giving up: after a confirmation the host who taps it loses and the other host wins (`pk_give_up_v2`, reason forfeit, even when
  the host is ahead). The final bell still decides by score. On a server without the migration the battle goes on and a message says why.
- **Viewers can switch sides**: in a battle a viewer taps the OTHER host's side (the right frame of a video battle, the blue half of an audio one; a small
  switch mark shows it can be tapped), sees a card with that host's name and picks "Go to <name>'s room". This room is left (its screen is taken down first,
  and the Agora engine of the old screen is closed before the next one is created) and the other host's live opens; there the sides swap (its own host is on
  the left), so tapping the other side takes the viewer back. Same kind only (the other live of the battle), hosts never get it (`visitOpponentRoom`,
  `ActiveLiveSessionController.replaceWith`, `AppNav.switchToLive`).
- **Room skin**: Tools -> Room skin works as in any audio live; the two halves are see-through when the room has a skin.

## Do all phones see the same battle? (checked 2026-10-19, `test/pk_sync_test.dart`)
Four simulated phones (host A, host B, a viewer of each room) with four different wrong clocks and one shared server row pass through a whole
battle: invite, 3-2-1, live, gifts from both rooms, final bell, result; also a draw, a give-up, a phone that drops off, a viewer joining in the
middle, and old / repeated rows. What is the SAME on every phone: the phase and its moment, the two scores, the clock (within a second,
counted against the server's clock, not the phone's), who the opponent is, the move into the battle's shared channel and back, and the
result (a win for A is a win for A's host and for A's viewers, a loss for B's, with the same two numbers mirrored). What is PER ROOM by design:
the room's own host is on the left, so B's room shows the same battle mirrored; chat, seats and guests belong to the room; the OTHER room's seats
in an audio battle are read every 8 s (not live). What recovers by itself: a phone that missed a row (a dropped connection, the background)
asks the server for the battle when the app returns, once a minute while live, and a few seconds after the final bell if no closing row has
come (`PkBattleController.refresh`).
Known difference from an ordinary live: a gift sent from room B to host A shows its animation in room A (where it lands) and to the sender; the
other viewers of room B see only the score change.

## The PK look: animations and colours (2026-10-20; set from the panel's PK Battles page, "Look and colours")
The owner's PK animation pack is bundled in `assets/pk/` (18 SVGA files, 3.3 MB; `tool/pk_assets/README.md` says what each is). Audio and
video PK share every one of them, because they are drawn by the shared layer:

| Moment | Animation | Code |
|---|---|---|
| looking for an opponent / waiting for the other host | `pk_matching` (looping, above the status strip) | `PkBattleHeader._setup` |
| an invite to me | `pk_svga` crossed swords, on the Accept / Decline card | `PkBattleEvents._showIncoming` |
| the Invite PK sheet | `pk_start_anim` "PK" logo | `_PkInviteSheet` |
| the countdown | `pk_anim` gloves clash, then `pk_count_down` 3-2-1 (exactly the 3 s), over a light dim | `PkBattleEvents.build` |
| the bell (countdown -> live) | `room_battle_start_animator` "VS" burst, full screen, 2 s; only for the moment the countdown ends | `PkBattleEvents._startBurst` |
| optional intro | `live_pk` full-screen splash behind the 3-2-1 (replaces the VS burst); off by default | panel switch |
| the score bar (audio arena AND the video stage) | `pk_progress_red` / `pk_progress_blue` bars clipped to each side's share, `pk_progress_battle` shield where they meet, `pk_mic_red` / `pk_mic_blue` swords at the ends (the `_rtl` files in right-to-left languages) | `PkTugBar` (`pk_tug_bar.dart`) |
| video PK only: between the two frames | `room_battle_start_animator` again, small (laid out 160 x 284, its letters about 60 px across), centred on the gap: it plays its opening flash once and then repeats only its steady shimmer (`PkSvga(loopFrom: 0.55)`); with animations off, or if the file fails, a small gold "VS" pill. It never takes a tap | `PkVideoStage._versus` |
| the result | `live_pk_win_icon` / `live_pk_lose_icon` / `live_pk_draw_icon`, or `lose` (crying face) when the panel picks that for losses | `PkBattleEvents._showResult` |

`pk_progress_blue.svga` is not in the pack: `tool/pk_assets/make_progress_blue.py` makes it from the red one (hue turned, the bar's vector fill set to the
blue sword's hue).

**Panel control.** `app_config.pk_theme` (migration `20261020100000_pk_theme.sql`, additive, nullable, check-constrained; rollback
`supabase/rollbacks/20261020100000_down.sql`) is one small JSON object: `mine`, `theirs`, `accent`, `bg_top` and `bg_bottom` (each `#rrggbb`; the last two are the gradient behind the VIDEO PK stage, a deep violet into a dark navy by default, where it used to be plain black: `PkVideoBackdrop` around the stage in both video screens), `animations` and `hero_intro`
(true / false) and `lose_style` (`shield` or `emoji`). Every key is optional, and an empty value means the built-in look (the red / blue / gold the
app always had). `PkThemeStore` (`lib/state/pk_theme_store.dart`) loads it with the branding (launch, resume, a panel save through the same Realtime update), keeps the
last one on the phone, and FAILS OPEN (an unreachable server or a database without the column changes nothing). A side's colour drives the arena
halves, the plain bars, the score panels' borders, the video frames, the confetti and, for the animations, a hue turn of the red / blue art
(`PkTheme.hueShift`, the art sits at hue 3 and 203; vivid colours work best, pale or grey ones cannot be shown by turning a hue).

**Live welcome warnings** (2026-10-21; one for VIDEO lives and video PK, one for AUDIO lives and audio PK). A new arrival gets, in their OWN chat only, their "joined"
line and under it a house-rules warning (`arrivalLines`, called from `_loadRealChat` in `watch_live_screen.dart` for video and in `watch_audio_room_screen.dart` for
audio; nobody else's chat gets it, ghosts see nothing, the host's own screen is unchanged; the shared server line "joined the live stream" is not shown to its own
author because the local one replaces it). Each kind has its own text and on / off switch: `app_config.video_warning_*` / `audio_warning_*` (migration
`20261020110000_live_welcome_warnings`, set from the panel's Application Configuration -> Live welcome). `LiveWarningStore` loads them with the branding and FAILS OPEN
(both on, each with its own built-in wording) when the columns are not there. The built-in texts are translation keys 832 (video) and 833 (audio); a text typed in the
panel is shown exactly as written, to everyone, untranslated, at most 600 characters.

**The viewer's tap on the other host's frame** (the swap mark) was swallowed by the viewer screen's gradient scrim, a plain `DecoratedBox` above the video (a decorated
box is a hit-test target). It is `LiveScrim` now (`IgnorePointer`); `test/live_scrim_test.dart` pins it. Remember this for any full-screen paint layer over live video.

**Switching the animations off** (`animations: false`, for weak phones or lag reports) gives the plain look every screen had before: gradient bars, a
diamond, the big countdown number, text results with confetti for a win. A file that cannot be played falls back to the same plain visual for that
piece only. Never shown while a file is still loading (it would flash).

Cost to know: during a battle five small animations loop (two bars, two swords, the shield), each in its own repaint layer (the live screen's lag
rule); the panel switch turns them all off. Tests: `test/pk_look_test.dart` (theme, store, widget fallbacks, bar, the moments), `test/pk_assets_test.dart`
(every file decodes in the real player at the expected size and length).

## Code
- App: `lib/state/pk_battle_controller.dart` (state machine over the server row), `lib/data/pk_battles_repository.dart` (`PkBattlesApi`),
  `lib/services/pk_channel_switcher.dart`, `lib/features/live/widgets/pk_battle_widgets.dart` (setup strip, invite sheet, events, video stage, confetti),
  `pk_battle_arena.dart` (the audio arena, the 4-seats-a-side rule, the opponent's seat reader), wired into `live_broadcast_screen.dart`, `watch_audio_room_screen.dart`, `watch_live_screen.dart`, `go_live_setup_screen.dart`.
- Server: migrations `20261017100000_pk_layer_foundations.sql`, `20261017110000_pk_layer_functions.sql` (`pk_invite_v2`, `pk_random_join`,
  `pk_begin_v2`, `pk_forfeit_sweep` + cron, `pk_now`, ...), rollbacks in `supabase/rollbacks/`, test `scripts/db/tests/pk_layer_test.sql`;
  `agora-token` lets seat guests publish in a layer battle (`battle_access.ts`). The old `invite_pk_opponent` family still serves the old screens.
- Old app builds are never offered as opponents (`live_streams.pk_ready`).

## Rules (table `pk_config`, one row; edited on the panel's PK Battles page)
Invite lengths {300, 600, 1800, 2400} s, random 300 s, forfeit grace 60 s (45-85), 6 invites a minute per host, random search expiry 20 s.

## Rollout order
Migrations on production (one per `scripts/prod/promote_step.sh` run; the seat-request one, `20261019100000_pk_seat_requests_v2.sql`, is optional for the rest and can follow later) -> deploy `agora-token` -> switch `pk_battles` on in the panel for the test
phones -> two-phone test -> Play bundle with PK off -> switch on after production validation. Video PK later, after measuring Agora minutes.
See `HANDOFF.md` (not in git) for the checklist and status.
