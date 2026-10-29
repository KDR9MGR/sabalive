# SUD games (a second game provider, next to Tulasi)

Status (2026-10-28): the games run in SUD's **NATIVE Android / iOS SDK** (their Flutter plugin `sud_gip_plugin`), inside the same game panel as every other game. The first version used SUD's WEB SDK in a page of
ours; SUD's test environment answered it with **error 10005 ("Invalid app platform information") for every game** (Ludo too, with either bundle id) and SUD's team then said the games are for Android and iOS, not the web.
The native route is built and unit-tested (fake SDK); it has NOT yet been run against SUD's servers with a real game (needs a phone and the owner's keys): the owner's first test decides. The database part and the `sud` Edge Function
(deployed on production by the owner) are unchanged: the callbacks are platform independent. Switches `sud_games_enabled` / `sud_coin_games_enabled` are the panel's; Android only for now (iOS hides the Games entries).

## What it is
SUD ("GI Cloud", console.sud.tech) hosts multiplayer party games (Ludo, Domino, UNO-style cards, Carrom, Okey, ...) and a few games that stake coins
(Teen Patti, Texas Hold'em, ...). Unlike Tulasi (a game URL we open), SUD gives an **SDK**: a native view that draws the game inside our app (their plugin wraps the Android / iOS SDK).
Players in the same live room play at the same table (room id = the live's id; outside a live the table is private to the person).

```
app (Android)  --POST sud/launch (user JWT)-->  Edge Function `sud`  --sud_launch_check-->  database (switches, age, ghost, hidden/off)
      |                                               | mints a one-time login CODE (HS256) + a longer LAUNCH token, answers with an address
      |  (the address only CARRIES the values: appId, appKey, gameId, roomId, userId, code, t, api, test, lang)
      v
SudGameScreen (lib/features/games/sud_game_screen.dart) in the game panel: native view -> SudGipPlugin.initSDKWithEnv -> loadGame(userId, roomId, code, gameId, language, view info, config)
      |  code expired -> POST <api>/refresh {t}  (the launch token proves it)     "back to lobby" state -> closes the panel
      v
SUD's servers --signed callbacks--> Edge Function `sud`:
    get_sstoken, update_sstoken, get_user_info, report_game_info, notify          (every game)
    get_account, get_score, update_score                                          (coin games only)
```
The old web page (`/sud/play` on the landing site) is no longer used by the app; it stays deployed (harmless) and can be removed later.

## Where things are
| Part | Files |
|---|---|
| Database (additive, one migration) | `supabase/migrations/20261026110000_sud_games.sql`, rollback `supabase/rollbacks/20261026110000_down.sql` |
| Edge Function (deploy `--no-verify-jwt`; it checks everything itself) | `supabase/functions/sud/` (`auth.ts` tokens, `signature.ts` HMAC-SHA1 check, `protocol.ts` callbacks, `launch.ts`, `index.ts`) + `*.test.ts` |
| Native game screen (what the app uses) | `lib/features/games/sud_game_screen.dart` (panel + loading / failure / renew code / pause), `sud_bridge.dart` (the plugin behind a small interface, so tests use a fake), `sud_launch.dart` (reads the launch address, view info, config, failure text); Android: `android/gradle.properties` (`sudGipArtifact`), `android/app/proguard-rules.pro`; tests `test/sud_native_game_test.dart` |
| Old hosted game page (NOT used any more) | `sabaliveadmin/landing/src/pages/SudPlay.jsx` (+ `lib/sudGame.js`, `lib/sudParams.js`), route `/sud/play`, outside the site layout |
| App | `lib/data/games_repository.dart` (`GameProvider`, `sud_games` read, `sud/launch`), `lib/features/games/*`, `lib/state/games_store.dart` |
| Panel | Games page: "SUD games" card (`src/pages/master/games.jsx`, `src/lib/sudGames.js`, `src/data/sudGames.js` = 59 presets from SUD's list); switches in Config > Release controls |
| Tests | `scripts/db/tests/sud_games_test.sql`, `sud_games_rollback_test.sql`, `scripts/test_functions.sh`, `test/sud_games_test.dart`, panel `npm test`; staging: `scripts/staging/verify_sud_games.sh` |

## SUD's test environment and the four callbacks (their message of 2026-10-26)
SUD's team: "Deploying the game takes 1-2 days; we will first deploy a test environment for you to use, and in the meantime you can prepare the four server-side callbacks required for testing"
(get_sstoken, update_sstoken, get_account, update_score). All four are live in the `sud` function on production (verified against SUD's docs field by field on 2026-10-26: request fields, response
fields, `ret_code` 0 = success, the special codes 9000 insufficient balance / 9001 duplicate order id, HMAC-SHA1 signature verification mandatory for get_account and update_score). The addresses to give SUD
(the console only has fields for the first two; the two coin callbacks are configured by SUD's staff, "test and production URLs are separate and Sud configures both"):
  get_sstoken     https://<project-ref>.supabase.co/functions/v1/sud/get_sstoken
  update_sstoken  https://<project-ref>.supabase.co/functions/v1/sud/update_sstoken
  get_account     https://<project-ref>.supabase.co/functions/v1/sud/get_account
  update_score    https://<project-ref>.supabase.co/functions/v1/sud/update_score
(plus report_game_info and notify, which have console fields). Things that must be true for a coin game to work in their test: the game is ADDED in the panel (Games > SUD games) with its SUD game id and
"Stakes wallet coins: Yes" (update_score for a game that is not in `sud_games` as a coin game is refused with ret_code 1), the 'SUD games' and 'SUD coin games' switches are on, and the player is 18+ with a date of
birth. The secrets are read ignoring capitals (`env.ts`), so SUD_App_Key and SUD_APP_KEY are the same setting. `scripts/prod/setup_sud.sh --check` shows which secrets exist (names only).

## Why it is isolated from the Tulasi games
SUD games live in their OWN table `sud_games`, not in `merchant_games`: an old app build reads `merchant_games` and would show a game it cannot open, and Tulasi's
"Sync Game List" switches every row that is not Tulasi's off. Old builds never read or call anything SUD. Internal ids start at 1,000,000 (Tulasi's are in the thousands) so
the new app's one merged list never mixes them; SUD's own 19-digit game id is kept as TEXT (JavaScript cannot hold it exactly).
Coin games reuse the Tulasi plumbing on purpose: the same `game_config` limits (max bet, payout multiple, daily limits), the same `game_transactions` audit table and the
same wallet ledger kinds `game_bet` / `game_win` (note `sud:<game id>`), so the existing monitoring reports cover them.

## Switches (all default OFF; Config > Release controls, Super Admin)
- `games_enabled` (existing master switch) must be on.
- `sud_games_enabled`: the SUD games show and can be opened.
- `sud_coin_games_enabled`: games marked "stakes coins" can be opened and move wallet coins. Needs the one above. Turn it on only after the same store / legal review the
  Tulasi games need (Play simulated-gambling policy, 18+ rating, Indian online-gaming law). A coin game also needs a date of birth on the profile and an age of
  `game_config.min_age` (18 by default); a party game has no age rule of its own (the app already asks for 13+ at the date-of-birth step). A ghost account can never play.
A switch-off or a Hide reaches open phones at once (Realtime on `sud_games` and `app_config`). A bet is refused while the coin switch is off, but the win of a bet placed before is still paid.

## What the owner has to do (nobody else can)
1. **SUD console** (console.sud.tech): finish the enterprise verification, top up the balance if needed (billing is per game per monthly active user, about USD 0.12-0.15), and note
   the application's App ID, App Key and App Secret. **Never paste them in chat.**
2. Set the Supabase secrets and deploy the function on PRODUCTION with ONE command, run by him in his own terminal: `scripts/prod/setup_sud.sh` (hidden prompts for the App Key and App Secret, asks him to type
   `production`, sets SUD_APP_ID / _KEY / _SECRET / SUD_TEST_ENV=1, deploys `sud --no-verify-jwt`, checks that it answers; `--check` only looks). The values never go through chat or a file that stays. (Manual way, for staging first):
   `SUD_APP_ID`, `SUD_APP_KEY`, `SUD_APP_SECRET` (optional `SUD_GAME_PAGE_URL`, default `https://www.sabalive.in/sud/play`; `SUD_TEST_ENV` default `1` = SUD's test environment, set `0` at launch).
3. Deploy: `supabase functions deploy sud --no-verify-jwt` (after the migration).
4. In the SUD console, application settings: **Web bundle_id = `www.sabalive.in`** (the page's hostname; the SDK sends `location.hostname`, and `sabalive.in` redirects to `www.sabalive.in`, so the page runs on www; a mismatch is SUD error 10005; it was `sabalive.in` until 2026-10-28), and the callback URLs
   `https://<project-ref>.supabase.co/functions/v1/sud/<route>` for `get_sstoken`, `update_sstoken`, `get_user_info`, `report_game_info` and `notify`, plus `get_account`, `get_score`
   and `update_score` for coin games. SUD has a TEST and a PRODUCTION environment with separate configuration; SUD staff set the URLs per environment, so ask them to
   enable both and to enable the optional callbacks.
5. In the console, **Add Games** (a game must be added in the console AND in the panel's SUD games card). Upload a picture for each in the panel (SUD's icons are not available to us).
6. Panel: Games > SUD games > Add game; then switch `sud_games_enabled` on (test accounts first; the staging project is the place).

## Known unknowns / things to watch
- **10005 on the web SDK (2026-10-28) is why the games moved to the native SDK.** `initSDK` -> `POST https://sg-sim-mg-sdk.s00.tech/v1/sdk/get_token` (SUD's TEST environment) answered "Invalid app platform information" for Teen Patti Pro, Pirate Fishing, Fruit Party and Ludo alike,
  with `sabalive.in` and `www.sabalive.in` as bundle id, while the console listed both; SUD's team then said the games work on Android and iOS, not on the web. (Earlier fixes that were real but not the cause: the WebView refused the apex -> www redirect, the
  console's Web bundle_id lacked `www.sabalive.in`, the page sent `www.`.) The app is registered for the native route already (console: Android and iOS `com.sabalive.in`).
- **Which SDK edition:** SUD has a Standard SDK (`tech.sud.gip:SudGIP`, small) and a Pro SDK (`SudGIP-pro`, all games). The Ludo / Teen Patti / Texas Hold'em / Domino / UMO / Carrom / Okey / Liar's Dice rows of SUD's table are "Standard or Pro". We ship the Standard, STATIC build
  (`SudGIP-static`, about 20 MB for the ABIs we ship): the plain artifact downloads native libraries at run time, which Google Play does not allow. **Pirate Fishing and Fruit Party are not in SUD's public table**: ask SUD which edition they need. `SudGIP-pro-static` is about 130 MB for four ABIs (the Play bundle would grow to roughly 300 MB in total; Play's own size table allows 500 MB and counts the download for ONE phone, so it is likely fine, and x86 can be dropped with `flutter build appbundle --target-platform android-arm,android-arm64` if needed); the Pro SDK also needs the second platform-view kind, which `PluginSudBridge` already uses.
- **iOS**: the plugin is in the iOS build too (CocoaPods `SudGIP`), but the Games entries are hidden on iOS for App Store review; the iOS Info.plist / SUD console iOS entry are untested.
- Not yet run against SUD's servers with a real game through the native SDK (callbacks are unit-tested with signed simulated requests; the first real test needs a phone). The staging DB part is proven.
- "Pro" TeenPatti / Texas Hold'em need the entry-with-score API (a second phase); the plain coin games use `update_score` as built.
- Some games (e.g. Carrom) are not on the web SDK yet: they are in the preset list only if SUD lists them for the web.
- The game panel is 1080 x 1669 px (`kSudGameAspect` = 1669 / 1080 = 1.545) for every SUD game: the owner's choice on 2026-10-28 from a screenshot of a game on their phone (the game fills it edge to edge); SUD's per-game minimum sizes and the panel's per-game proportions are no longer used by the native screen. The round close button sits in a row above the panel, outside the game.
  right and may sit over a game's own top-right control: tune on a phone.
- Per-game cost: every game added raises the monthly bill by its price x monthly active users; add only what is wanted.
- The database has 60 connections: the callbacks are short, one RPC each; do not add polling.

## Rollback
Panel/app: switch `sud_games_enabled` off (instant). Database: `supabase/rollbacks/20261026110000_down.sql` (drops the SUD objects only; coins already moved stay in the ledger).
Function: `supabase functions delete sud` (nothing else calls it).

## Checks before any production step
`scripts/db/replay_migrations.sh` ALL_OK (with `scripts/db/tests/sud_games_test.sql`), `scripts/test_functions.sh`, `flutter analyze` (baseline 12) and `flutter test`, panel `npm test` and
`npm run build:site`, `scripts/staging/verify_sud_games.sh` ALL PASSED, then the usual `docs/DEPLOY_CHECKLIST.md` (backup, dry run, `scripts/prod/promote_step.sh 20261026110000 --apply`, healthcheck + smoke).
