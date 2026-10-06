# Staging: a safe copy to test on before production

Production is shared with the live Play app, so nothing risky should be tried there first. Staging is a
**second Supabase project** (the free plan allows two) plus a **test build** of the app that talks to it.

## What you get
- Try every migration and Edge Function on staging first (`scripts/staging/db_push.sh`).
- A staging APK that shows an orange **STAGING** ribbon and can never write to production
  (`scripts/staging/build_apk.sh`). The app itself refuses to start if the two are mixed up.
- A Play build is always production: `scripts/release/build_play_bundle.sh` refuses staging flags and checks the
  finished bundle only contains the production address.

## One-time setup (about 20 minutes)
1. **Create the project.** Supabase dashboard > New project > name `sabalive-staging`, region Sydney (same
   as production), a strong database password. Save the password in your password manager.
2. **Save its details outside the repo** in `~/sabalive-secrets/staging.env` (this folder is already where
   the release key lives; never commit it):
   ```
   STAGING_REF=xxxxxxxxxxxxxxxx
   STAGING_URL=https://xxxxxxxxxxxxxxxx.supabase.co
   STAGING_PUBLISHABLE_KEY=sb_publishable_...        # Project Settings > API
   STAGING_DB_PASSWORD=...                           # the password from step 1
   ```
3. **Apply the schema:** `scripts/staging/db_push.sh` (dry run), then `scripts/staging/db_push.sh --apply`.
4. **Auth settings** (Authentication > URL Configuration): add the redirect URL `com.sabalive.in://login-callback/`.
   Email provider on; turn "Confirm email" off so test accounts work at once.
5. **Edge Functions:** deploy each function to staging with
   `supabase functions deploy <name> --project-ref $STAGING_REF`. Set its secrets in the staging dashboard
   (Edge Functions > Secrets). `agora-token` needs `AGORA_APP_ID` and `AGORA_APP_CERTIFICATE`: use a
   SEPARATE Agora project for staging, or live video on staging will spend production's minutes.
6. **Test accounts:** create a Super Admin and a few ordinary users on staging with fake data. **Never copy a
   production backup into staging**: it contains real people's data.
7. **Build the test app:** `scripts/staging/build_apk.sh`. It saves `~/sabalive-releases/sabalive-staging-<version>.apk`.
   It has the same package name as the Play app, so install it on a phone that does not have the Play
   version (or uninstall that first).

## Using it day to day
1. Write the migration and its down script. `scripts/db/replay_migrations.sh` must say ALL_OK.
2. `scripts/staging/db_push.sh --apply`, then use the staging app (and the panel pointed at staging) to try it.
3. Only then follow `docs/DEPLOY_CHECKLIST.md` for production.

## Limits to know about
- A free project **pauses after 7 days without activity**; unpause it in the dashboard before testing.
- Staging has no real users and no real traffic, so it cannot tell you how a change behaves under load or
  with old Play builds: keep the additive-only rule (see the checklist) and run
  `scripts/prod/smoke_play_app.sh` after every production push.
- The Google sign-in button needs staging's Auth > Providers > Google configured; email login works without it.
- The panel is separate. To try a panel change against staging, create `sabaliveadmin/.env.staging.local` with
  `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` for staging, and run `npm run dev -- --mode staging`.
  Leave `.env.local` alone: it holds the production values.
