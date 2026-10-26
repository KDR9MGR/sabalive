# Keeping old, modified and fake copies of the app out (plan, 2026-10-27)

Status: PLAN ONLY. Nothing here is built except step 0. Written after the owner asked to expire every previous build and to stop "modification or other security breach".

## What a version gate can and cannot do
Step 0 (built): the **minimum Android version code** in the panel (Application Config -> Release Settings). A build older than the minimum shows a full-screen "Update required" (`update_required_gate.dart`).
Limits, so nobody is surprised:
- It only stops OFFICIAL older builds that contain the gate (shipped 2026-10-06; the +7 bundle and older do not have it).
- It runs INSIDE the app, so a modified or repackaged copy simply removes the check. It cannot stop tampering.
- It fails open on purpose (no network = not blocked), so it is a nudge with teeth, not a lock.
Real protection has to be decided by the SERVER, from something the app cannot fake. That is what the steps below add.

## What we are defending against (and what stops it)
| Threat | Today | Stops it |
|---|---|---|
| An old official build still in pockets | version gate (builds from 2026-10-06 on) | step 1 (server-side version) |
| A repackaged / modded APK (checks removed, coins or referral abuse scripted) | nothing | step 2 (Play Integrity, checked by the server) |
| Rooted phone, emulator, farm of fake devices | device-id bans only | step 2 (device verdict) |
| Calling our API without the app (the anon key is public by design) | RLS + `SECURITY DEFINER` RPCs | already the real wall; steps 3 and 4 tighten it |
| A leaked secret | `service_role` and SUD / Tulasi keys live only in Edge Function secrets | keep it that way |

## Step 1: the server refuses old builds itself (about 1 day, rehearse on staging)
The app already knows its build number. New builds send it with every request (`Supabase.initialize(headers: {'x-app-build': ...})`). Edge Functions (`agora-token`, `sud`, `tulasi`, `send-push`) reject a build below `app_config.min_android_version_code` with a plain "update required" answer. For the database, a PostgREST `db_pre_request` function can do the same for REST / RPC calls, so even a build WITHOUT the screen is cut off server-side (it just sees an error). Caveats: a pre-request hook runs on every call (keep it a single indexed read of one row, cached per transaction), it is a global setting (`alter role authenticator set pgrst.db_pre_request`), so it needs a staging rehearsal, a down script and a kill switch; and a modified app can still lie about its build number, which is why step 2 exists.

## Step 2: Play Integrity, verified on our server (about 1 week of work + 2 weeks in shadow mode)
Google's Play Integrity API tells the server, with a signed token the app cannot forge: this is the genuine app, installed from Google Play, signed with our key, on a genuine, unmodified device.
1. **Owner, once:** link the Play Console app to a Google Cloud project, enable the Play Integrity API, create a service account with the right to decode tokens, and put its key in a Supabase secret (named `PLAY_INTEGRITY_SA`, set by the owner, never in chat or git). Check the free daily request quota (about 10,000 a day by default) against the number of daily sessions; Google raises it on request.
2. **App (Kotlin channel next to `device_ids`):** use the Standard API: prepare the integrity provider once at launch, then ask for a token bound to a request hash (user id + the action + a server nonce) when a sensitive action starts. No new Dart package needed beyond a thin channel.
3. **Edge Function `integrity` (new, `--no-verify-jwt` like `sud`, checks the user JWT itself):** gives out a nonce, receives the token, decodes it with Google, and checks: request hash matches; `appRecognitionVerdict = PLAY_RECOGNIZED`; `packageName = com.sabalive.in`; certificate digest = Google's app-signing certificate; `deviceRecognitionVerdict` contains `MEETS_DEVICE_INTEGRITY`; `appLicensingVerdict = LICENSED`. It writes a row to a new table `device_attestations(user_id, device_id, verdict, verified_at, expires_at)` (additive migration, RLS: nobody reads it from the app).
4. **Shadow mode first (2 weeks):** record the verdict, enforce nothing, and measure how many real users would fail (custom ROMs, no Google services, sideloaded APKs, the owner's own test APKs: they are NOT Play-signed and will fail by design, so they need an allow-list of device ids).
5. **Enforce only where it matters:** coin-moving and abuse-prone actions (send gift, game bet, withdrawal request, referral redeem, account creation burst), using NEW `..._v2` functions that call `attested()` (rule: only add while old apps are live; the old functions are retired when the minimum version moves past the last build that uses them). Viewing a live, chatting and browsing are never blocked. Fail OPEN if Google is down or the quota is hit, and fail closed only on a definite "not recognised" verdict.
6. **Panel:** a Release control switch `integrity_enforce` (default OFF), a count of verdicts by kind, and an allow-list page.
7. **iOS (later, iOS is unreleased):** the equivalent is App Attest / DeviceCheck, same table, same Edge Function.

## Step 3: cheap hardening in the app build (about 1 day)
- Dart obfuscation in release builds: `flutter build appbundle --obfuscate --split-debug-info=<dir>` (keep the symbols folder safe, it is needed to read crash traces). R8 shrinking is already on.
- Keep the Play signing certificate fingerprint check inside the Edge Function (step 2.3), not in the app.
- No secret ever ships in the app: the app holds only the public anon key (already true).

## Step 4: review the server side, which is the real wall (about 2 days)
- List every `SECURITY DEFINER` function an app user can call that moves coins, XP, diamonds or roles, and confirm each checks `auth.uid()` and the amount on the server (most do; this is an audit, not a rewrite).
- Rate limits on gifting, referral redeem and OTP (per user and per device); an alert when one account moves an unusual amount.
- `scripts/prod/check_levels.sh`-style read-only checks for coins and diamonds (ledger sums equal balances), run weekly.

## Order, effort, decisions
1. Step 3 and the owner's Google Cloud setup (2.1) can start now and cost nothing to users.
2. Step 1 (staging, then production on the owner's word).
3. Step 2 in shadow mode, then decide with real numbers whether to enforce.
4. Step 4 alongside.
Decisions the owner has to make: whether to enforce at all or stay in shadow mode; what to do for users who fail (a friendly "install from Google Play" message, and a support path); the allow-list of test devices; whether the Play Integrity quota is enough.

## What this will not do
No scheme makes a phone app impossible to modify. The aim is to make abuse expensive and visible, and to make sure a modified copy cannot move coins or reach other people's data, because the server decides.
