# Deploying to production (the live Play app is using it)

One Supabase project serves the live Play app, the admin panel and our testing. Anything you push
is live for every user the moment it lands. Old app versions stay in people's pockets for months, so
**the database must keep working for every app version that is out there**, not just the newest.

Read the rules, then follow the steps. Every script lives in `scripts/`.

## The rules

**1. While an old app version is live, change the database only by adding to it.**

| Safe (additive) | Needs care (small steps, down script ready; a quiet hour makes it cheaper) | Never while an old app is live |
|---|---|---|
| new table, new column with a default, new function with a NEW name, new index (`concurrently`), new Edge Function | `create or replace` of a function the app calls (the behaviour changes for everyone), a new trigger or RLS policy on a busy table, `alter column ... type` (rewrites the table, locks it), a bulk `update` (every changed row is a Realtime event for every phone) | renaming or dropping a column, table or function the app uses; changing a function's arguments or return type; making a column `not null`; tightening an RLS policy the app depends on |

To change something in the third column: add the new version next to the old one (`..._v2`), ship an
app that uses it, wait until almost nobody runs the old app, and only then remove the old one.

**2. Everything goes through a migration file in git.** Never run SQL by hand in the dashboard on
production. (This is how the repo and the database drifted apart: the push said "already exists,
skipping" for migrations someone had applied by hand.) Emergency hand fixes must be turned into a
migration the same day.

**3. One person pushes, from a clean `main`.** `supabase db push` applies EVERYTHING pending,
including migrations other sessions committed and nobody reviewed. If `--dry-run` lists a migration
you did not mean to ship, stop and ask.

**4. Every migration has a way back.** Put a `supabase/rollbacks/<version>_down.sql` next to it (see
`supabase/rollbacks/README.md`) before pushing. It is never run automatically.

**5. Maintenance mode and "log out all users" are not a first response.** Signing out everyone creates
a login wave, and the Google sign-in error appeared for many people at exactly that moment. Use
them for planned work (with auto-end ON) or after the other steps below have failed.

**6. Run migrations at any hour, when the owner says so.** There is no quiet-window rule (the owner removed it on 2026-10-18).
For information only: traffic is lowest roughly 21:00-04:00 UTC (02:30-09:30 IST) and highest around 14:00-20:00 UTC, so a
change from the middle column of the table costs less in a quiet hour. Everything else in this list (backup, health check,
smoke test, dry run, the owner's explicit go) still applies at every hour.

## Before a push

- [ ] `flutter test` and `flutter analyze` pass (no new analyzer infos).
- [ ] **Replay on a scratch database:** `scripts/db/replay_migrations.sh`  ->  `ALL_OK`.
      For a new migration, also write a small test SQL and run `scripts/db/replay_migrations.sh my_test.sql`.
- [ ] **Rehearse on staging:** `scripts/staging/db_push.sh --apply`, then `scripts/staging/check.sh` must end ALL PASSED
      (health + the 12-step Play-app smoke test). Try the change in a staging app build or the staging panel
      (`docs/STAGING.md`). Anything that fails there never reaches production.
- [ ] Classify each migration with the table above. Anything in the middle column: plan the steps
      and write the down script. Anything in the third column: stop, redesign.
- [ ] `supabase/rollbacks/<version>_down.sql` exists for each new migration.
- [ ] `supabase db push --dry-run` lists **only** the migrations you intend to ship.
- [ ] **Baseline:** `scripts/prod/healthcheck.sh` is clean and `scripts/prod/smoke_play_app.sh` passes.
      If production is already unhealthy, do not push.
- [ ] **Backup:** `scripts/prod/backup.sh`  ->  `BACKUP OK`. Takes about 10 minutes (one query per table), so start
      it first. (The free plan has no automatic backups.)
      It is saved in `~/sabalive-backups/`; it contains user data, so never commit or share it.
- [ ] Tell the team (and note the time) before you start.

## Push

- [ ] `supabase db push` (read the list once more at the prompt).
- [ ] Edge Functions, if changed: `supabase functions deploy <name>`, ONE at a time, checking after each.
      Tag the commit first (`git tag prod-YYYYMMDD-HHMM`) so the previous version is easy to redeploy.

## Right after (within minutes)

- [ ] `scripts/prod/healthcheck.sh`: all PASS (no new WARN compared with the baseline).
- [ ] `scripts/prod/smoke_play_app.sh`: ALL PASSED.
- [ ] Watch for 15 minutes: is the number of lives and joins about what it was? Open the app on a real
      phone running the Play build and do one live: join, chat, take a seat.
- [ ] Note what was pushed (migration versions, who, when) in the QA tracker.

## If something breaks

1. **Look first, don't react.** Run `scripts/prod/healthcheck.sh`. Is the API answering? Are connections
   near the limit (60 on this plan)? Did Postgres restart? Are background jobs failing?
2. **Run `scripts/prod/smoke_play_app.sh`.** The first FAIL names the broken thing.
3. **If a migration you just pushed is the suspect,** apply its down script (`supabase/rollbacks/`).
   Then run the two scripts again. Remove the version from the migration history only if you want a
   later push to apply it again (`supabase migration repair --status reverted <version>`).
4. **If the database stops answering for everyone** (the CLI times out, the status call returns 504):
   check status.supabase.com, then the dashboard (Reports > Database), then Restart project. Check
   Logs > Postgres for out-of-memory or too-many-connections lines before restarting.
5. **Only then** consider maintenance mode (scheduled, auto-end ON, a message users can read). Do not
   use "log out all users" unless sessions themselves are the problem.
6. Write down what happened (QA tracker, one row). The cause matters more than the fix.

## Supabase login (the CLI must act as the sabalive account)
The CLI keeps one stored login per computer, and it has been switched to the wrong account more than once (it then shows `habitpro` and a personal project, and every
check answers 403 or "could not query the database"). Fix it once for good with an **access token kept in a file outside git**:

1. In the Supabase dashboard, signed in as the sabalive account: profile icon > Account preferences > **Access Tokens** > Generate new token (name `sabalive-cli`, give it an
   expiry, 90 days is sensible). Copy it once; it is shown only then.
2. Save it into `~/sabalive-secrets/supabase.env` (that folder is outside every repo; the file must be mode 600) WITHOUT putting it in chat or in your shell history. In your terminal:
   `mkdir -p ~/sabalive-secrets && read -rs "T?Paste the token, then press Enter: " && print -r -- "SUPABASE_ACCESS_TOKEN=$T" > ~/sabalive-secrets/supabase.env && chmod 600 ~/sabalive-secrets/supabase.env && unset T && echo saved`
3. Check: `cd sabalive && set -a && . ~/sabalive-secrets/supabase.env && set +a && supabase projects list` must show `sabalive` and `sabalive-staging`.

Every script under `scripts/prod/` and `scripts/staging/` loads that file by itself (`scripts/lib/supabase_login.sh`; a token already in the environment wins; without the file nothing changes).
A plain `supabase db push` typed in a terminal does NOT load it: prefix it with the same `set -a && . ~/sabalive-secrets/supabase.env && set +a &&`, or use `supabase login` as before.
The token has the same power as your login (every project of the account): keep the file at mode 600, never commit or paste it, and revoke it in the same dashboard page if it ever leaks.

## Edge Functions and secrets
- Never put a secret in the repo. Function secrets live in Supabase (Edge Functions > Secrets).
- `agora-token` needs `AGORA_APP_ID` and `AGORA_APP_CERTIFICATE`. A second environment (staging) must use
  its own Agora project or it will spend production's minutes.

## Limits to watch (free plan today)
- Database connections: 60 total. Healthcheck warns at 60% and fails at 85%.
- Egress: 5 GB cached / month (11 GB used in October). Media is re-downloaded on every launch until the
  app gets a disk cache.
- Agora: minutes are billed per person per minute; HD video counts for several times audio.
