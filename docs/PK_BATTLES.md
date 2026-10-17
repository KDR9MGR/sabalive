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
   audio battle; in a video battle they only listen). Header: both hosts, score bar, clock; audio shows the other room's people.
4. At 00:00 a host's phone (or the server within a minute) finishes it: result dialog, everybody returns to their own channel.
5. A host who ends the live or is silent for 60 s loses (forfeit); the other host wins.

## Code
- App: `lib/state/pk_battle_controller.dart` (state machine over the server row), `lib/data/pk_battles_repository.dart` (`PkBattlesApi`),
  `lib/services/pk_channel_switcher.dart`, `lib/features/live/widgets/pk_battle_widgets.dart` (header, invite sheet, events, stage, opponent
  room, confetti), wired into `live_broadcast_screen.dart`, `watch_audio_room_screen.dart`, `watch_live_screen.dart`, `go_live_setup_screen.dart`.
- Server: migrations `20261017100000_pk_layer_foundations.sql`, `20261017110000_pk_layer_functions.sql` (`pk_invite_v2`, `pk_random_join`,
  `pk_begin_v2`, `pk_forfeit_sweep` + cron, `pk_now`, ...), rollbacks in `supabase/rollbacks/`, test `scripts/db/tests/pk_layer_test.sql`;
  `agora-token` lets seat guests publish in a layer battle (`battle_access.ts`). The old `invite_pk_opponent` family still serves the old screens.
- Old app builds are never offered as opponents (`live_streams.pk_ready`).

## Rules (table `pk_config`, one row; edited on the panel's PK Battles page)
Invite lengths {300, 600, 1800, 2400} s, random 300 s, forfeit grace 60 s (45-85), 6 invites a minute per host, random search expiry 20 s.

## Rollout order
Migrations on production (one per `scripts/prod/promote_step.sh` run) -> deploy `agora-token` -> switch `pk_battles` on in the panel for the test
phones -> two-phone test -> Play bundle with PK off -> switch on after production validation. Video PK later, after measuring Agora minutes.
See `HANDOFF.md` (not in git) for the checklist and status.
