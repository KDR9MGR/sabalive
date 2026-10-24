# Sourced by the production and staging scripts: makes the Supabase CLI act as the SABALIVE account, whatever `supabase login` last stored on this Mac.
#
# The CLI keeps ONE stored login per computer, and it has been switched to the wrong account (habitpro / a personal project) several times, which makes every
# check fail with 403 / "could not query the database". The CLI always prefers the SUPABASE_ACCESS_TOKEN environment variable over that stored login, so if
# ~/sabalive-secrets/supabase.env exists (outside every git repo, mode 600) it is loaded here:
#
#     SUPABASE_ACCESS_TOKEN=sbp_...
#
# Create it yourself (never paste the token in chat or into a command that is saved in your shell history): see docs/DEPLOY_CHECKLIST.md > "Supabase login".
# Without the file nothing changes: the stored login is used as before. A token already in the environment wins.
_SUPABASE_ENV_FILE="${SUPABASE_ENV_FILE:-$HOME/sabalive-secrets/supabase.env}"
if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ] && [ -f "$_SUPABASE_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$_SUPABASE_ENV_FILE"
  set +a
fi
unset _SUPABASE_ENV_FILE
