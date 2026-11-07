# Production release: the batch of 2026-11-06 / 07

Nothing here is on production until the owner says "go" for that step. Production is shared with the live Play app: read `docs/DEPLOY_CHECKLIST.md` and the root CLAUDE.md first.

## State on 2026-11-07 (read-only check)
- Production already has every migration up to `20261106140000` EXCEPT the eight below (`scripts/prod/healthcheck.sh`, section 3).
- The production PANEL already contains the VIP Products page, Kill stream, Pull back and the "Limit each admin to their own chain" switch. The VIP page says "needs the database update" until `20261106120000` is applied.
- Play has build +16 (tag `play-16-bundle`, 2026-11-01). The bundle of this batch is **1.0.0+18** (a tester APK once used +17; Play accepts any higher number, so 18 is safe).

## What is in the batch
**Database (8 migrations, all additive; each has `supabase/rollbacks/<version>_down.sql` and an SQL test in `scripts/db/tests/`)**
1. `20261102100000` each admin sees only their own chain (another session's; behind a Release switch that is OFF by default). **Owner decides: ship or hold.**
2. `20261105100000` couple (CP) seats.
3. `20261106110000` lifetime rankings (gifters, agencies).
4. `20261106120000` VIP products.
5. `20261106130000` `live_streams.rtc_provider` (which server carries a live).
6. `20261107100000` game-win notices (table + trigger on `game_transactions`).
7. `20261107110000` gift notices (table + trigger on `live_chat_messages`, fires only for a gift row).
8. `20261107120000` shared live hearts (table + `add_live_hearts`).
**Edge Functions:** `agora-token` (couple-seat microphone rule; deploy AFTER 2), `livekit-token` (new; needs three secrets only when MS cloud is turned on).
**App (Play bundle +18):** lifetime ranking tab; golden seats, 36 px seats, tighter rows; CP seats; gift and game-win strips (5,000+ coins) on Home and in rooms; shared hearts and count (host chip too); clean chat bar with Send, 3-line chat window; country flags, one-grid emoji picker; VIP "coming soon"; email-only sign-in; MS cloud code, OFF until the server switch is turned on; iOS 2.0.0 (1) is separate.
**Panel:** a new Release control "MS cloud for new lives" (local commit, deploys with the next panel push).

## Order (never the other way round: DB first, then functions, then the app)
0. Before anything: the app is committed and tagged (`play-18`), the bundle is built and verified, and one two-phone pass has been done on staging.
1. Owner decides about `20261102100000`.
2. `scripts/prod/backup.sh` (BACKUP OK; do NOT run it at the same time as other CLI calls), then `scripts/prod/healthcheck.sh` and `scripts/prod/smoke_play_app.sh` clean.
3. Migrations one at a time, in this order, each with a dry run first (`scripts/prod/promote_step.sh <version>`) and then `PROMOTE_CONFIRM=<version> scripts/prod/promote_step.sh <version> --apply` (one transaction, `lock_timeout 5s`, health + smoke before and after, prints the down script on a failure):
   `20261105100000`, `20261106110000`, `20261106120000`, `20261106130000`, `20261107100000`, `20261107110000`, `20261107120000` (and `20261102100000` only if the owner says ship).
4. `supabase functions deploy agora-token` (then `livekit-token`, harmless without secrets).
5. `scripts/prod/healthcheck.sh` + `smoke_play_app.sh` again; read the new objects.
6. Play: upload `~/sabalive-releases/sabalive-1.0.0+18-release.aab`, internal test first, then a staged rollout (for example 10% -> 50% -> 100%) watching Crashlytics.
7. Panel: push the "MS cloud for new lives" switch only with the owner's word (a push to `main` deploys `admin.sabalive.in`).

## MS cloud on production, later and separately
Setting the secrets does NOT turn MS cloud on for anybody. Four independent things: the secrets, the function, the database column, and the switch.
1. **Secrets** (owner): make `~/sabalive-secrets/livekit-prod.env` (mode 600; three lines `LIVEKIT_URL=wss://<name>.livecore.cloud`, `LIVEKIT_API_KEY=...`, `LIVEKIT_API_SECRET=...`; never in chat). Then `scripts/prod/livekit_setup.sh --secrets` (dry run: checks the file, says what it would set, names only; refuses the staging key), and with the owner's go `LIVEKIT_CONFIRM=sfehzhtqtpuobnrvzvzp scripts/prod/livekit_setup.sh --secrets --apply`. The old pair that was pasted in chat must be revoked at LiveCore.
2. **Function**: `LIVEKIT_CONFIRM=sfehzhtqtpuobnrvzvzp scripts/prod/livekit_setup.sh --deploy --apply`, then `scripts/prod/livekit_setup.sh --check` (read-only; HTTP 401 "must be signed in" is the healthy answer; 404 = not deployed yet, which is today's state, 2026-11-07).
3. **Database**: migration `20261106130000` (`live_streams.rtc_provider`) from the list above.
4. **Switch**: panel -> Application Config -> Release controls -> "MS cloud for new lives" (Super Admin, key `rtc_livekit_new_lives`, default OFF). It only shows once the panel is pushed with commit "MS cloud for new lives". It is ALL OR NOTHING for every host on the new app: there is no cohort. Turn it on ONLY when Play +18 is at 100% and the minimum Android version code has been raised, because an older app lists an MS cloud room and cannot join it. Off again = every new live back on Agora at once, no release; lives already running keep their server.
5. Before the switch: staging has the same code, so repeat the check there on two phones (audio room, video live, a seat, 10+ minutes on a seat for the token renewal) and look at PK, music, beauty and 1:1 calls (Agora only).
