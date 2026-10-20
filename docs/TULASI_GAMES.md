# Tulasi games (merchant integration)

Status: built and tested on STAGING only (2026-10-13; live updates added the same day). Nothing of this is on production. Games are OFF by default
(`app_config.feature_flags.games_enabled`, Application Config -> Release controls, Super Admin). Android only; iOS shows "coming soon".

## What it is
Tulasi hosts the games (Teen Patti Gold, Lucky99, Roulette, ... authorised for merchant 1503251 = SABALIVE). Their servers call three
endpoints on OUR backend, and our app opens each game in a WebView with a per-launch token.

| Platform calls (POST, body = RSA-encrypted string) | We answer | Where |
|---|---|---|
| `.../userInformation` `{token, gameType}` | `{id, coin, gameCoin, nickname, avatar}` | `game_get_user` |
| `.../updateBalance` `{token, uid, transactionId, type, coin, timestamp, gameEndTimestamp, ...}` type 0 = bet, 1 = win | `{id, coin}` | `game_apply_balance` |
| `.../updateGameList` `[{id, name, image, banner, gameIdentification, status, ...}]` | `code 1` | `game_sync_list` + pictures copied to our storage |

The reply is JSON `{code, msg, data}`: code 1 = success and `data` is encrypted with the platform's public key; a refusal is `code 0`, a short `msg`, no data
(the platform's documentation does not say which code a failure must use: confirm with its Request Tester).
Encryption: RSA PKCS#1 v1.5, text cut into 200-byte pieces, each piece base64, joined by `:` (`supabase/functions/tulasi/rsa.ts`).
Game URL: `https://gamesp.tulasigame.com/<identification>/?merchant=1503251&gameId=<id>&lang=en&isLandscape=false&roomId=111&token=<token>`.
The game asks the app to close or open the coin shop with `tulasigame://exit` and `tulasigame://recharge` (the WebView intercepts them).

## How a change in the Tulasi panel reaches the app (and where games show)
The platform does NOT tell us about edits by itself. Edit names / pictures / on-off / new games in the Tulasi dashboard, then press **Sync Game List** there: it pushes the whole list to
`/updateGameList`, we store it in `merchant_games` (pictures copied into `gift-assets/games/...`; games missing from the push are set to Off), and Realtime delivers the change to every open
app within about a second (`GamesStore`: coalesced 0.5 s, plus a re-read when the app returns to the front). The panel's own **Games** switch (Application Config -> Release controls) is
`app_config.feature_flags.games_enabled`; the app listens to `app_config` too, so flipping it shows or hides the games on open phones at once.
Games appear in: the **Games** tab, a **Games row on Home** (under the banner; hidden while off / not Android / empty, "See All" opens the tab), and the **Games** item in the More menu inside
audio, video, host and PK rooms. Inside a room a game opens as a sheet over the live (`AppNav.route`), so the live keeps running behind it. The panel's Games page lists "Games received
from Tulasi" (what the platform last sent, On/Off, last sync time).
Realtime needs `app_config` / `merchant_games` in the publication; if it is not there the app still loads the list on open, on resume and on pull-to-refresh.

## How a game is shown (the panel)
A game opens as a PANEL at the bottom of the screen (`lib/features/games/game_panel.dart`: `showGamePanel`, `GamePanelRoute` + `GamePanelFrame`), not a full page. INSIDE A LIVE (opened from the room's More -> Games list) the Games
list is closed when the game opens, so the ROOM is what is above the panel, and the room stays fully usable (the route is an `OverlayRoute`, not a ModalRoute: no dim, no touch blocker; the room keeps running).
From the Games tab / Home the page stays visible above the panel, dimmed and blocked (so a second game cannot be opened on top of the first). A tap outside does NOT close it (a stray tap should not drop someone out of a round): the X in its header, the game's own exit
(`tulasigame://exit`) or the system back button does (back reaches it through the live's `maybePop`). If the game asks for the coin shop after the list was removed, it opens from the navigator's overlay context (`GameLauncher`). The games are Cocos canvases that keep the screen WIDTH and hang from the bottom edge, so the space a game needs is width x (design height / design
width), and anything taller is just empty (this was the "half game, half black screen" bug of the first sheet, which gave every game 90% of the screen). The panel therefore asks the page for its
size (`cc.view.getDesignResolutionSize()` through the WebView, polled every 0.5 s, then every 3 s) and animates to it. A game gets the height its layout asks for, up to the whole screen below the status bar (the old 90% cap cut the TOP of tall games, where their table and info sit, off: fixed 2026-10-19); when even the whole screen is too short the game is drawn narrower at its own proportions (`gamePanelGameWidth`, black sides) instead of being cropped. Measured on 2026-10-13: Teen Patti Gold, Dragon Tiger
Battle and Lucky99 are square (750x750), Greedy and Roulette are 750x1200 (1.6); the rest start from the table in `game_panel.dart` and are corrected by the page.
GOTCHA: every game reports the engine template's 750x1334 from the moment its page starts and switches to its own size only after its assets have loaded (about a minute on a slow line, a few seconds on a
good one), so that starting value is ignored for 90 s (`kEngineDefaultGrace`); trusting the first answer draws a square game as a tall panel with an empty top. What a page reported is remembered for the
next open (`rememberGameAspect`). A NEW game the platform adds needs no app update: it starts tall and settles at its real size once loaded.

## Running it without touching code (what the Tulasi guide allows, read 2026-10-13)
The documented integration is THREE callbacks from the platform to us (`userInformation`, `updateBalance`, `updateGameList`) and the game URL. There is NO documented pull API (nothing we can call to fetch the list), no
admin API and no schedule for the push: the list reaches us only when the platform pushes it (the **Sync Game List** button, next to Save on Basic Configuration and on Merchant Game Config; the guide says to press it after changing a
game's URL, status or display information). Automating Tulasi's admin site (login + captcha, the owner's password in our backend) is NOT an option: undocumented, fragile, and a credential risk.
Who owns what, and how a change reaches players:
- Tulasi dashboard: which games exist / are enabled, names, pictures, description, game address / node (Singapore `gamesp`, Germany `gamede`; the push carries `gameDomain`, so a node change reaches the app with the next sync, no app update), chips, round length,
  multipliers, commission, RTP interventions, robots, prize pool, coin icon (64x64 png). Gameplay settings apply on the platform at once (press "Update cache" if a change does not show); the LIST our app shows changes when Sync Game List is pressed.
- Our panel (Games page + Release controls): the Games switch (all games on/off, live in open apps), the limits our server enforces, the received-games list, the watch reports.
- Code: nothing for a new / renamed / disabled game: the URL is built from `gameIdentification` + `gameDomain`, the panel sizes itself from the page, pictures are copied to our storage at sync. The game's own code updates on the platform's side (the URL redirects to the newest version).
Manual or external, cannot be automated from our side: pressing Sync Game List (ask Tulasi whether it can push automatically on every change or offers a pull endpoint / schedule); prize-pool top-ups; reconciliation against the Record Query logs (no API); the callback URL (ONE per merchant: staging now, production at launch);
keys (rotate with Reset in the dashboard, then `supabase secrets set`).
DATES: the dashboard shows an account **Expire Date: 2026-11-22 14:00:00** (UTC+8); games stop when it passes unless Tulasi renews it. Per-game `expirationDate` arrives with the sync in `yyyy-MM-dd HH:mm:ss` and is UTC+8 (our `game_sync_list` currently reads it as UTC: 8 hours late; fix before using it to hide games).
The guide also offers a **TulasiGame SDK** (Android AAR / iOS XCFramework / Flutter plugin zip, `openGame` / `preloadGame` / `clearCache`) that caches each game's package for faster opening, with an online-WebView fallback; "Portrait / Half Screen" is the isLandscape=false mode our panel uses. Not adopted: it is a vendor binary
inside our Play app, and it may open its own full-screen container instead of our panel. Read its README (the owner downloads it) before deciding.

## Runbook: adding, changing and curating games on a running app (no app update, no SQL, no deploy)
The merchant has **44 games** (Merchant Game Config shows 10 per page, 5 pages) and all are switched on in Tulasi. What players see = ON in Tulasi **and** not hidden in our panel.
1. **Add / rename / re-picture / switch on or off at the platform:** Tulasi dashboard -> Merchant Game Config -> change it (Edit, the Enable switch, Batch Switch Status) -> **Sync Game List** -> Confirm. The toast must say
   "Sync game list success" (if it says "fail", see "If a Sync fails"). Open apps update in about 15 s: names and status at once, pictures a few seconds later (they are copied to our storage after we answered, see below).
2. **Keep a game out of the app without touching Tulasi:** our panel -> Games -> "Games received from Tulasi" -> the row's menu -> "Hide from the app" (or Hide all, then show the ones you want one by one). Works at once, a Sync never undoes it,
   and the server refuses a launch of a hidden game. New games from a later Sync are SHOWN by default: check the list after each Sync (the "Last sync" column) and hide what you have not tested.
3. **Everything off / on:** Application Config -> Release controls -> "Games" (Super Admin). **Our limits** (largest bet, daily loss / win, payout multiple, minimum age): Games page.
4. **Game rules** (chips, round length, commission, RTP, robots, prize pool): Tulasi dashboard -> Edit; press "Update Cache" if a change does not show. These apply to the game at once, no Sync needed.
5. **Before a game is shown to real players:** open it once on a phone (a live and the Games tab), place a small bet, check the balance, the history and the Games page's "Every balance call" table.
If a Sync fails: the dashboard says "Sync game list fail" and nothing changes on our side. Causes seen so far: (a) our function ran out of CPU decrypting the 44-game body with pure-JS RSA (HTTP 546 WORKER_RESOURCE_LIMIT; fixed by the runtime's
native RSA, see `rsa.ts`, header `x-decrypt: native`), (b) it answered too slowly because it copied the pictures first (they are copied after the answer now). Also check the callback URL (ONE per merchant: staging now), the two secrets, and `supabase functions deploy tulasi --no-verify-jwt --use-api`.
What the platform REALLY sends differs from its documentation: the Request Tester's sample has only `id, merchantId, name, image, gameIdentification` (image as a relative path, no status / banner), the real Sync sent full links, banner, status and `gameDomain`
(`https://gamesp.tulasigame.com`, no trailing slash: the app adds it). The function and `game_sync_list` accept both (a missing status keeps the old one, a new game starts enabled; relative picture paths are completed with the picture host; `expirationDate` is UTC+8).
Pictures: the platform's links are saved at once, then copied to `gift-assets/games/...` a few at a time and the rows pointed at our copies (`setImage`, only if the row still holds the platform link a newer Sync must not be undone).

## Pieces
- Migrations (additive, each with a rollback and a SQL test): `20261013100000_tulasi_games` (config, players, sessions, transactions, the three functions, ledger kinds
  `game_bet` / `game_win`), `20261013110000_tulasi_game_list` (`merchant_games`), `20261013120000_tulasi_game_monitoring` (two watch views).
- Edge Function `supabase/functions/tulasi/` (deploy with `--no-verify-jwt`; unit tests: `scripts/test_functions.sh`, no Deno needed).
- App: `lib/data/games_repository.dart`, `lib/state/games_store.dart` (the live list), `lib/features/games/{games_screen,games_strip,game_launcher,game_webview_screen}.dart`, dependency `webview_flutter`.
- Migration `20261013130000_tulasi_games_realtime`: `merchant_games` joins the Realtime publication and every signed-in user may read every row (disabled games too), so a switch-off reaches open phones.
- Panel: `Games` page (limits, 14-day totals, watch reports, every balance call) + the `Games` switch in Release controls.

## Money rules (all in `game_apply_balance`, one transaction)
Exactly once per `transactionId` (a repeat returns the stored answer); the wallet is locked while it is changed; a bet needs enough coins; a request more than 2 s old or after
the round's end time is refused; a bet above `max_bet` or beyond the daily loss/win limit is refused; a win is accepted only after a bet on that game in the last 15 minutes and
not above `max_payout_multiple` x those bets (otherwise kept as `rejected` for a human). The wallet moves through the existing ledger trigger, so `wallets.coins >= 0` still
protects every balance. Refused calls are kept in `game_transactions`.
A launch (`start_game_session`) needs: signed in, not a ghost, games ON, a date of birth that makes the person at least `min_age` (18). Only the SHA-256 of the token is stored.

## Decisions taken by the owner, and what stands behind them
1. **The dashboard decides the game rules and outcomes** (we do not change its settings). Its guide says that with Platform Commission % above 0 the platform adjusts outcomes;
   there are New-User / Loss-Streak / Win-Streak interventions and robot players on leaderboards. Only commission 0 is "fully fair random". The in-app notice says plainly that results
   are decided by the provider's system, which may adjust outcomes. Please do not remove that sentence without a lawyer's advice.
2. **Normal coins** (not a separate game wallet): winnings are ordinary coins, so "win -> gift a host -> withdraw" exists. The Games page has two watch reports for it; a separate one-way game
   wallet remains the safer design.
3. **Android first.**

## Before production (the owner's explicit go for each; see PROMOTION_2026-10.md for the order)
- Store and legal review (Google Play simulated-gambling / deceptive-behaviour rules, 18+ rating, Indian online-gaming law). A policy strike could remove the whole app.
- Confirm with Tulasi: fees / revenue share, the dashboard's expiry (2026-11-22 was shown), the failure `code` for a refused call, IP addresses to allow-list, a second merchant or test account
  (the dashboard has ONE callback URL, so switching it between staging and production is a manual step).
- The callback encryption is not authentication (anyone with our public key could encrypt a request): keep the key private, rely on the per-launch token + uid match + payout rules above.

## Setting it up on STAGING (owner)
1. Set the two secrets (values from the Tulasi dashboard: "Private Key (Merchant)" and "Public Key (Platform)"; never paste them in chat or commit them):
   `supabase secrets set TULASI_MERCHANT_PRIVATE_KEY="$(pbpaste)" --project-ref gsloixbaktefwgxzjtps` (copy the key first), then the same for `TULASI_PLATFORM_PUBLIC_KEY`.
2. In the dashboard: Callback URL = `https://gsloixbaktefwgxzjtps.supabase.co/functions/v1/tulasi/` (keep the trailing slash), Save. Use "Encrypt Test" / "Decrypt Test", then the Request Tester
   for userInformation, updateBalance and updateGameList (it needs a real token: start a game from the staging app, or ask for one).
3. Staging panel -> Application Config -> Release controls -> switch "Games" on. Staging test accounts already have a date of birth.
4. Staging APK -> Games tab -> pick a game.
