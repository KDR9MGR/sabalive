# Rollback ("down") scripts

For every migration in `supabase/migrations/<version>_name.sql` that changes behaviour, keep a matching
`supabase/rollbacks/<version>_down.sql` that puts the database back the way it was before.

- They are **never run automatically**, and `supabase db push` ignores this folder (it is not inside
  `migrations/`). Someone applies one by hand, deliberately, when a push has gone wrong.
- Write it **before** pushing, while you still remember what the old definition looked like. The
  previous version of a function is in an earlier migration (`grep -l "function public.<name>" supabase/migrations/*.sql`),
  or in the last backup's `schema/functions.sql`.
- Start with `_TEMPLATE_down.sql`.
- Say plainly what a rollback can NOT undo (rows that were repaired, data written after the push).
- Test it on the scratch database: `scripts/db/replay_migrations.sh my_down_test.sql`.
- After applying one, run `scripts/prod/healthcheck.sh` and `scripts/prod/smoke_play_app.sh`. If you want
  a later `supabase db push` to apply the migration again, run
  `supabase migration repair --status reverted <version>`.
