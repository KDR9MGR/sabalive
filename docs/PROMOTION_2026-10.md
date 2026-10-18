# Promotion: staging work -> production (October 2026)

> **2026-10-18: the time-of-day rule in this plan (the quiet window 21:00-04:00 UTC, `--any-hour`) was removed by the owner.** `promote_step.sh` no longer checks the hour and ignores `--any-hour`; everything else below still applies. See `DEPLOY_CHECKLIST.md`.

Status: PLANNED, nothing of this is on production yet. Written 2026-10-12. Follows `DEPLOY_CHECKLIST.md` (read it first).
Nothing below runs without the owner saying "go" for that step in chat; a past "go" covers one step.

## The order, and why
Owner's order: confirm the list -> panel (part 1) and Play bundle -> after Google's review the database -> panel (part 2) -> let users update.
Three safeguards make that order safe:

1. **Panel in two parts.** Panel `develop` reads and writes columns production does not have yet (`gifts` / `store_items`:
   `play_speed`, `sound_url`; `lucky_box_config.cooldown_hours`; the profile assign/remove actions need `20261012100000`). Part 1 ships now
   (nothing that touches a new column), part 2 right after the database.
2. **Managed publishing ON before the review.** Otherwise "approved" means "live", and the new app would reach users while the database is
   still old (it degrades quietly: no room admins / kick / ban text / add-4-seats, `send_gift_to_all` falls back, no instant leave).
3. **Soak between the database and the publish.** The danger of a database change is to the OLD app (+7 is what is live). After the last
   migration, let production run through one evening peak (14:00-20:00 UTC) with only +7 live, then publish, then a staged rollout
   10% -> 25% -> 50% -> 100%. If something breaks you then know which change did it.

## Sequence
| # | Step | Where | Needs |
|---|---|---|---|
| 0 | Commit `develop` (app, panel, monorepo pointers); tag the live Play commit `play-live` (candidate `6ac5860`, 2026-10-04 18:46, the commit before the +7 bundle was built at 18:52); final two-phone QA of the staging APK | repos | owner's go |
| 1 | **Panel part 1** to production (worktree off `origin/main`, like the environment switch): screen-protection switch, Emotes & GIFs rename, branding preview, staging mode. Excludes play speed / sound, Lucky Box cooldown, profile assign/remove. Check: no `play_speed`, `sound_url`, `cooldown_hours`, `admin_remove_user_` in the release tree | panel | owner's go |
| 2 | **Play bundle** `1.0.0+8` with `scripts/release/build_play_bundle.sh` -> internal testing (try it on a real phone against PRODUCTION: the old-database fallbacks) -> **turn Managed publishing ON** -> send for review | Play | owner's go |
| 3 | **DB tier A** while Google reviews (additive, any off-peak hour, `--any-hour`): `20261009120000`, `20261009110000`, `20261009140000`, `20261012110000`. Record only: `20261007100000`, `20261007120000` (their objects are already on production, applied by hand: read-only check, then `--record-only`) | DB | owner's go per migration |
| 4 | **DB tier B**, quiet hour 21:00-04:00 UTC (02:30-09:30 IST), ONE migration per run, fresh backup first: `20261009090000` -> `20261009100000` -> `20261010090000` -> `20261010100000` (its own night) -> `20261012100000` | DB | owner's go per migration |
| 5 | **Panel part 2** to production: effect speed / sound fields, Lucky Box cooldown field, profile assign/remove (`d9786bf`) | panel | owner's go |
| 6 | **Soak** through one evening peak with +7 live: `healthcheck.sh`, `smoke_play_app.sh`, lives / joins normal | - | - |
| 7 | **Publish** (Managed publishing), phased 10 -> 25 -> 50 -> 100%; pause on a crash / ANR rise or a healthcheck WARN | Play | owner's go |
| 8 | Merge `develop` -> `main` in both repos and the monorepo, tag `prod-YYYYMMDD`, update the QA tracker | repos | owner's go |

## What is in it
### Edge Functions
None changed since production's deploys (`system-ops` v1 is already live). No `functions deploy`.

### Database (`supabase/migrations`, each with `supabase/rollbacks/<version>..._down.sql`)
| Version | What | Class | Effect on the OLD app |
|---|---|---|---|
| 20261007100000, 20261007120000 | capability grants, View user profile | already on production (by hand) | none; record only |
| 20261009090000 | `push_notification()` reads its address from Vault | function body | none (no secret = the production address) |
| 20261009100000 | leaving frees the seat; sweep after 75 s of silence, every 15 s; partial index | 2 function bodies + cron + index | an old app is dropped after 75 s of silence instead of 90 s |
| 20261009110000 | `send_gift_to_all`, `live_chat_messages.to_all` | new function + column with a default | none |
| 20261009120000 | `play_speed`, `sound_url`, audio upload types | nullable columns | none |
| 20261009130000 | Lucky Box pull back | already applied | - |
| 20261009140000 | `app_config` added to the Realtime publication | publication | one small event per panel save |
| 20261010090000 | Lucky Box 24 h cooldown | 2 function bodies | every host: one reward per 24 h from then on |
| 20261010100000 | room admins, kick, ban text, seat counts 4..25 | 6 function bodies, 3 tables, a BEFORE INSERT trigger on `live_chat_messages`, a check | none; the new moderation exists only in the new app |
| 20261012100000 | (other session) assign / remove on a profile: Bag items, Lucky ID, badges, frames; Host Assignment delete | 4 function bodies, 2 functions, policies | staff panel only |
| 20261012110000 | 53 more emotes | data, idempotent | an old app just shows a longer picker |

Rehearsed on staging: all of them applied, `scripts/staging/check.sh` ALL PASSED (health + 12-step Play-app smoke test), `verify_new_features.sh` ALL PASSED.
On a scratch Postgres: `replay_migrations.sh` ALL_OK (148), one SQL test per migration in `scripts/db/tests/`, and `rollback_chain_test.sql` runs every
down script newest-first without an error (it found, and I fixed, a wrong drop order in the moderation down script).

### Panel (`develop` ahead of `main`)
Part 1 (no new column): screen-protection switch and branding preview (`config.jsx`, `appPalette.js`), Emotes & GIFs rename (`nav.js`, `liveEmojis.js`, and only the
emote hunks of `store.jsx`), staging mode (`1140b7a`; it also makes the landing site read its project from the environment, defaulting to production).
Part 2 (needs the database): effect speed / sound (`coins.jsx`, `store.jsx` speed hunks, `coins.js`, `store.js`, `effectFields.js`, `storage.js`, `EntityForm.jsx`),
Lucky Box cooldown (`platform.jsx`, `luckyBox.js`), profile assign / remove (`d9786bf`).
`store.jsx` mixes both kinds, so part 1 is built by re-applying only the part-1 edits on a worktree off `origin/main`, not by copying files; the exclusion check is
`grep -rn "play_speed\|sound_url\|cooldown_hours\|admin_remove_user_" src` = no hits.
Already live: System Overview, Lucky Box pull back, the production / staging switch (Vercel has the two staging variables).

### App `1.0.0+8` (84 files uncommitted at the time of writing)
Instant leave, send to All, effect speed / sound, host-only Lucky Box timer, room skins, keyboard, theme / branding from the panel, 4-per-row seats with
frames inside their cell, room admins / kick / ban / ban text / report (audio AND video), wave colours and waves for other speakers, right-hand video
seats, 60-character chat, @mentions, level banner (charm picture, own banner, no double entry), emotes over the picture circle, seat-glitch hardening,
social-login banners, Store (Garage -> Room Skin), profile frames, screen protection (panel switch, default off), friendly errors for an older server.
Almost all client-only. What each DB-dependent feature does on an OLD database: room admins / kick / ban text are hidden, Add / Remove seats refuses with a
friendly message, send to All falls back to one gift per person, effect speed uses the app default (0.75x), the Lucky Box cooldown line is absent.

## The tool
`scripts/prod/promote_step.sh <version>` does ONE migration with a safety net (it never runs `db push`):
```
scripts/prod/promote_step.sh 20261010100000                                     # dry run: every check, changes nothing
PROMOTE_CONFIRM=20261010100000 scripts/prod/promote_step.sh 20261010100000 --apply
PROMOTE_CONFIRM=20261007100000 scripts/prod/promote_step.sh 20261007100000 --apply --record-only
scripts/prod/promote_step.sh <version> --staging [--apply]                      # the same on staging (rehearsal)
```
It checks: the file and its down script exist; the target project (production only if the link folder is production); the version is pending; quiet window
(production, unless `--any-hour`); a backup under 6 h old (production); health check without a FAIL; the Play-app smoke test. It applies the file in one
transaction with `lock_timeout 5s`, records it with `migration repair --status applied`, reruns health + smoke, and on a FAIL prints the down script to run.
It was used on staging for `20261012100000`.

## Before each production step
- [ ] The owner said "go" for this step in chat.
- [ ] `scripts/prod/backup.sh` ended `BACKUP OK` (tier B: just before it).
- [ ] `scripts/prod/healthcheck.sh` has no FAIL; `scripts/prod/smoke_play_app.sh` ALL PASSED.
- [ ] Tier B: inside 21:00-04:00 UTC.
After: both again, 15 minutes of watching lives and joins, one live on a real phone with the +7 Play build.

## If something breaks
Healthcheck first, smoke second, then that migration's down script (the tool prints the command). Maintenance mode and "log out all users" are last resorts.
Panel: revert the release commit on `main` (Vercel redeploys). App: halt the staged rollout.

## Games (Tulasi): ship dark, light them last (added 2026-10-13)
Games ride the same train as everything above, but nothing a player can see changes until the LAST step. Everything before it is inert: new tables and functions nobody calls, an Edge Function the platform does not
call yet (its callback still points at staging), a Games page in the panel, and an app whose `games_enabled` flag is off (absent = off; the Games tab says "coming soon" exactly as in +7).
Proven before any production step (2026-10-13): the 5 games migrations (`20261013100000` ... `140000`) replay cleanly on a copy of PRODUCTION's exact state (142 migrations, the 11 other pending ones left out: `REPLAY_SKIP`), their 4 SQL test
files pass there, `rollback_chain_test.sql` runs every down script, the wallet ledger check is re-added `NOT VALID` (no full-table scan under the lock that blocks coin movements; validate later with
`alter table public.wallet_ledger validate constraint wallet_ledger_kind_check;`), the real Tulasi Sync succeeds against staging (44 games, pictures copied), production health is OK (29 of 60 connections, 71 MB, no waiting locks).
| # | Step | Needs | Rollback |
|---|---|---|---|
| G1 | Commit `develop` in sabalive, sabaliveadmin and the monorepo pointers; nothing to `main` yet | owner's go | `git revert` |
| G2 | DB, one migration per run with `promote_step.sh` (backup first; `20261013100000` in the quiet window 21:00-04:00 UTC because it swaps one check on `wallet_ledger`, the other four any off-peak hour): `100000`, `110000`, `120000`, `130000`, `140000` | owner's go per migration | `supabase/rollbacks/<version>_down.sql` (newest first) |
| G3 | Edge Function: `supabase functions deploy tulasi --no-verify-jwt --use-api` to production, then the two secrets `TULASI_MERCHANT_PRIVATE_KEY` / `TULASI_PLATFORM_PUBLIC_KEY` (the SAME keys as staging: one merchant; copied from the dashboard, never pasted in chat). Test with a self-test script before anything depends on it. Inert until the callback URL moves | owner's go | `supabase functions delete tulasi` |
| G4 | Panel part 2 (already planned) now also carries the Games page, hide / show controls and the Games release switch | after G2 | revert the release commit on `main` |
| G5 | Play bundle `1.0.0+8` (contains the games code, switch off) -> internal testing -> Managed publishing -> review -> staged rollout (existing steps 2 and 7) | owner's go | halt the rollout |
| G6 | **LIGHT THE GAMES** (the only step players can see), only when ALL of these hold: store / legal review is done; the rollout has reached enough users; the list is curated (panel -> Games: hide what you have not tried); limits are set (panel -> Games -> Limits: largest bet, daily loss / win; the defaults have NO daily cap); keys are on production (G3); Tulasi's account expiry (2026-11-22) is renewed; then in this order: (1) switch the Tulasi dashboard callback URL to production (staging loses it: it is one per merchant), (2) press Sync Game List and check "success" and 44 rows, (3) play one small round with a staff account on production and check the balance and the Games page, (4) flip Release controls -> Games ON | owner's separate go | Release controls -> Games OFF (instant, every phone); callback URL back to staging |
| G7 | Watch: Games page (every balance call, the two watch reports), `healthcheck.sh`, connections (60 max: each game session holds none, balance calls are short) | - | - |
Things that stay manual by design: pressing Sync Game List after Tulasi-side changes; renewing the Tulasi account; deciding which games are shown.

## Run sheet for the database (2026-10-13)
Verified locally: the 14 pending migrations do not redefine each other's functions or triggers (only the games chain does: `140000` replaces `game_sync_list` / `start_game_session`), so they can be applied in groups. `20261007100000` and
`20261007120000` are only recorded: their 4 functions and 4 policies are in production's backup snapshot. The script stops at the first failure (`|| break`); each run does backup-age check, health + smoke before and after, and prints the down script on a FAIL.
Run from `sabalive/`. `--any-hour` (outside 21:00-04:00 UTC) is meant for ADDITIVE files only; the permission layer refuses it when I run it, so the owner runs these blocks in a terminal (or adds a Bash permission rule for `scripts/prod/promote_step.sh`).
```
# A. record-only + additive: any off-peak hour (peak = 14:00-20:00 UTC); needs a backup < 6 h old
for v in 20261007100000 20261007120000; do PROMOTE_CONFIRM=$v scripts/prod/promote_step.sh $v --apply --record-only --any-hour || break; done
for v in 20261009110000 20261009120000 20261009140000 20261012110000; do PROMOTE_CONFIRM=$v scripts/prod/promote_step.sh $v --apply --any-hour || break; done
# B. function bodies / triggers: quiet window 21:00-04:00 UTC (02:30-09:30 IST), no override; fresh backup first (about 12 minutes)
scripts/prod/backup.sh
for v in 20261012100000 20261009090000 20261009100000 20261010090000; do PROMOTE_CONFIRM=$v scripts/prod/promote_step.sh $v --apply || break; done
# C. its own night (adds a trigger on live_chat_messages)
PROMOTE_CONFIRM=20261010100000 scripts/prod/promote_step.sh 20261010100000 --apply
# D. games, in order (100000 swaps the wallet_ledger kind check: quiet window)
for v in 20261013100000 20261013110000 20261013120000 20261013130000 20261013140000; do PROMOTE_CONFIRM=$v scripts/prod/promote_step.sh $v --apply || break; done
```
After each block: `scripts/prod/healthcheck.sh`, then watch lives and joins for 15 minutes.
