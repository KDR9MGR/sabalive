# Staging: a safe copy to test on before production

Production is shared with the live Play app, so nothing risky is tried there first. Staging is a **second
Supabase project** (`sabalive-staging`, ref `gsloixbaktefwgxzjtps`, Sydney, in the same organisation) built
from the same migrations, with **fake data only**: no real users, chats or wallets.

## What exists today (built and tested)
- The whole schema (all migrations), the 7 background jobs, 3 storage buckets, realtime tables and the 6 Edge
  Functions are on staging.
- Catalog data from `supabase/seed.sql` (gifts, coin packages, badges, frames, legal pages). The alpha demo
  codes are removed.
- **Fake accounts**, all with `@staging.sabalive.test` and one shared password (`STAGING_TEST_PASSWORD` in
  `~/sabalive-secrets/staging.env`): `superadmin`, `master` (panel); `host1`-`host3`, `user1`-`user10` (app). Hosts can
  go live; hosts and users start with 50,000 coins.
- The push trigger is told to call **staging's** `send-push` (Vault secret `functions_base_url`), never production's.
- Both the production health check and the 12-step Play-app smoke test pass on it.
- Production is not touched by any of this: staging commands use their own link folder
  (`~/.sabalive-staging-workdir`), never `supabase/.temp` (which stays linked to production).

## Daily use
| To do | Command (from `sabalive/`) |
|---|---|
| See which migrations staging lacks | `scripts/staging/db_push.sh` |
| Apply them to staging | `scripts/staging/db_push.sh --apply` |
| Re-run setup (functions, secrets, fake accounts): safe to repeat | `scripts/staging/bootstrap.sh` |
| Check staging (health + 12-step smoke) | `scripts/staging/check.sh` |
| Check the newest features as real roles (send to All, instant leave, Lucky Box pull back, grants; all rolled back) | `scripts/staging/verify_new_features.sh` |
| Build a staging APK (orange STAGING ribbon) | `scripts/staging/build_apk.sh` |
| Run the panel against staging | `cd ../sabaliveadmin && npm run dev:staging` (uses `.env.staging.local`, git-ignored) |
| Back up staging | `SUPABASE_WORKDIR=~/.sabalive-staging-workdir SABALIVE_BACKUP_DIR=~/sabalive-backups/staging scripts/prod/backup.sh` |

The app refuses to start if a staging build points at production, and the panel does the same in staging mode.
A Play build never uses any of this: `scripts/release/build_play_bundle.sh` refuses staging flags and checks that the
finished bundle only contains the production address.

## Still to do by you (your accounts)
1. **Agora (for live video on staging).** Create a SEPARATE project in the Agora console (free 10,000 minutes) so testing
   never spends production's. Then
   `supabase secrets set AGORA_APP_ID=... AGORA_APP_CERTIFICATE=... --project-ref gsloixbaktefwgxzjtps`
   and add `STAGING_AGORA_APP_ID=...` to `~/sabalive-secrets/staging.env`. Until then staging's `agora-token` answers
   "Agora credentials are not configured" and no live video can start.
2. **Push notifications (optional).** Staging's `send-push` is deployed and safe; without `FCM_SERVICE_ACCOUNT_JSON` it
   skips sending. To test pushes, add a service account for a Firebase project and an Android app for the staging build.
3. **Auth settings** (Supabase dashboard, staging project > Authentication): turn "Confirm email" OFF if you want to test
   sign-up in the app (the fake accounts are already confirmed), and add the redirect URL `com.sabalive.in://login-callback/`.
   Google/Apple sign-in on staging needs its own provider setup; email login works without it.
4. **Panel on Vercel (optional).** A Preview deployment of the `develop` branch can use staging if you set the
   `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` values for the **Preview** environment only (never Production) in the Vercel
   project. `vercel.json` routes deep links only on `admin.sabalive.in`, so previews need a host rule first.

## Rules
- Staging has no real users or traffic. It proves a change WORKS; it cannot prove how it behaves under load or with old
  Play builds. Keep the additive-only rule (see `DEPLOY_CHECKLIST.md`) and run `scripts/prod/smoke_play_app.sh` after
  every production push.
- Never copy a production backup into staging: it contains real people's data.
- A free project **pauses after 7 days without activity**; unpause it in the dashboard before testing.
- Staging shares the organisation's quotas (egress, etc.) with production. Staging traffic is small, but the organisation
  is already over its free egress quota, so keep media-heavy testing short.
- The staging APK has the same package name as the Play app: install it on a phone without the Play version (or uninstall
  that first). A separate package id (an Android flavor) is a planned follow-up.
