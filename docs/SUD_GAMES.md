# SUD games (a second game provider, next to Tulasi)

Status (2026-10-26): built and unit-tested; the database part is applied to STAGING and passes `scripts/staging/verify_sud_games.sh`. Nothing of this is on production,
nothing is committed or pushed, and the `sud` Edge Function is NOT deployed anywhere yet (it needs the owner's SUD secrets). Both switches are OFF by default.
Android only (the game panel is the Android WebView); iOS keeps "coming soon" like the Tulasi games.

## What it is
SUD ("GI Cloud", console.sud.tech) hosts multiplayer party games (Ludo, Domino, UNO-style cards, Carrom, Okey, ...) and a few games that stake coins
(Teen Patti, Texas Hold'em, ...). Unlike Tulasi (a game URL we open), SUD gives a **web SDK** (`sudmgp-sdk-js`) that must run inside a page of OURS; the games are drawn
into it. Players in the same live room play at the same table (room id = the live's id; outside a live the table is private to the person).

```
app (Android)  --POST sud/launch (user JWT)-->  Edge Function `sud`  --sud_launch_check-->  database (switches, age, ghost, hidden/off)
      |                                               | mints a one-time login CODE (HS256) + a longer LAUNCH token
      | opens the address it gets in the game panel   v
      +--> https://sabalive.in/sud/play?appId=..&gameId=..&roomId=..&userId=..&code=..&t=..&api=..  (landing site, SDK runs here)
                      |  SudMGP.initSDK / loadMG(userId, roomId, code, gameId, lang, ...)
                      v
                SUD's servers --signed callbacks--> Edge Function `sud`:
                    get_sstoken, update_sstoken, get_user_info, report_game_info, notify          (every game)
                    get_account, get_score, update_score                                          (coin games only)
```
The page asks `sud/refresh` (proved by the launch token) for a new code when the SDK reports `onExpireCode`.

## Where things are
| Part | Files |
|---|---|
| Database (additive, one migration) | `supabase/migrations/20261026110000_sud_games.sql`, rollback `supabase/rollbacks/20261026110000_down.sql` |
| Edge Function (deploy `--no-verify-jwt`; it checks everything itself) | `supabase/functions/sud/` (`auth.ts` tokens, `signature.ts` HMAC-SHA1 check, `protocol.ts` callbacks, `launch.ts`, `index.ts`) + `*.test.ts` |
| Hosted game page | `sabaliveadmin/landing/src/pages/SudPlay.jsx` (+ `lib/sudGame.js`, `lib/sudParams.js`), route `/sud/play`, outside the site layout |
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
   `SUD_APP_ID`, `SUD_APP_KEY`, `SUD_APP_SECRET` (optional `SUD_GAME_PAGE_URL`, default `https://sabalive.in/sud/play`; `SUD_TEST_ENV` default `1` = SUD's test environment, set `0` at launch).
3. Deploy: `supabase functions deploy sud --no-verify-jwt` (after the migration).
4. In the SUD console, application settings: **Web bundle_id = `sabalive.in`** (the page's hostname; the SDK sends `location.hostname`), and the callback URLs
   `https://<project-ref>.supabase.co/functions/v1/sud/<route>` for `get_sstoken`, `update_sstoken`, `get_user_info`, `report_game_info` and `notify`, plus `get_account`, `get_score`
   and `update_score` for coin games. SUD has a TEST and a PRODUCTION environment with separate configuration; SUD staff set the URLs per environment, so ask them to
   enable both and to enable the optional callbacks.
5. In the console, **Add Games** (a game must be added in the console AND in the panel's SUD games card). Upload a picture for each in the panel (SUD's icons are not available to us).
6. Panel: Games > SUD games > Add game; then switch `sud_games_enabled` on (test accounts first; the staging project is the place).

## Known unknowns / things to watch
- Not yet run against SUD's real servers: everything above is built from SUD's documentation and unit-tested with signed simulated callbacks; the first real test needs the
  owner's secrets and the console set-up. The staging DB part is proven; the staging Edge Function has NOT been deployed.
- "Pro" TeenPatti / Texas Hold'em need the entry-with-score API (a second phase); the plain coin games use `update_score` as built.
- Some games (e.g. Carrom) are not on the web SDK yet: they are in the preset list only if SUD lists them for the web.
- The game panel draws at the height / width SUD gives (`sud_games.aspect`, from SUD's minimum-size table) at full width, with no header; the round close button floats at the top
  right and may sit over a game's own top-right control: tune on a phone.
- Per-game cost: every game added raises the monthly bill by its price x monthly active users; add only what is wanted.
- The database has 60 connections: the callbacks are short, one RPC each; do not add polling.

## Rollback
Panel/app: switch `sud_games_enabled` off (instant). Database: `supabase/rollbacks/20261026110000_down.sql` (drops the SUD objects only; coins already moved stay in the ledger).
Function: `supabase functions delete sud` (nothing else calls it).

## Checks before any production step
`scripts/db/replay_migrations.sh` ALL_OK (with `scripts/db/tests/sud_games_test.sql`), `scripts/test_functions.sh`, `flutter analyze` (baseline 12) and `flutter test`, panel `npm test` and
`npm run build:site`, `scripts/staging/verify_sud_games.sh` ALL PASSED, then the usual `docs/DEPLOY_CHECKLIST.md` (backup, dry run, `scripts/prod/promote_step.sh 20261026110000 --apply`, healthcheck + smoke).
