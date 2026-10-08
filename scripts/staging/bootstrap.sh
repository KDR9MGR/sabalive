#!/usr/bin/env bash
# One-time (and safe to re-run) setup of the STAGING project, after `scripts/staging/db_push.sh --apply`.
#
#   scripts/staging/bootstrap.sh
#
# It only ever talks to the staging project (its own link folder; production's link is never used) and
# refuses to run if staging.env points at production. It
#   1. tells the push trigger to call STAGING's send-push (Vault secret functions_base_url), so staging can
#      never call production,
#   2. deploys the 6 Edge Functions (send-push and request-account-deletion without JWT verification, as in prod),
#   3. gives send-push the secret the database signs its calls with,
#   4. loads the catalog (gifts, coin packages, badges, frames, legal pages) and removes the alpha demo codes,
#   5. creates FAKE accounts (a Super Admin, a Master, 3 hosts, 10 users) with a shared test password that is
#      saved in staging.env, and gives the users some coins.
# Not done here (your accounts): the Agora and FCM secrets (see docs/STAGING.md), and the Auth dashboard settings.
set -euo pipefail
cd "$(dirname "$0")/../.."

ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_REF:?}" "${STAGING_URL:?}" "${STAGING_DB_PASSWORD:?}"

PROD_REF=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE '//[a-z0-9]+' | tr -d '/')
if [ "$STAGING_REF" = "$PROD_REF" ] || [ "$STAGING_REF" = "$(cat supabase/.temp/project-ref 2>/dev/null)" ]; then
  echo "STAGING_REF is the production project. Refusing."; exit 2
fi
case "$STAGING_URL" in *"$PROD_REF"*) echo "STAGING_URL contains the production ref. Refusing."; exit 2;; esac

WORK="${STAGING_WORKDIR:-$HOME/.sabalive-staging-workdir}"
[ "$(cat "$WORK/supabase/.temp/project-ref" 2>/dev/null)" = "$STAGING_REF" ] || { echo "Run scripts/staging/db_push.sh --apply first (it links the staging folder)."; exit 2; }
export SUPABASE_DB_PASSWORD="$STAGING_DB_PASSWORD"

sql() { supabase db query --linked --workdir "$WORK" -o json "$1" 2>/dev/null | jq -c '.rows'; }
echo "Bootstrapping STAGING $STAGING_REF  (production $PROD_REF is not touched)"

# ---- 1. the push trigger must call staging, never production
echo "1. push trigger -> staging"
sql "do \$\$ declare v_id uuid; begin
       select id into v_id from vault.secrets where name = 'functions_base_url';
       if v_id is null then perform vault.create_secret('$STAGING_URL', 'functions_base_url', 'where send-push lives');
       else perform vault.update_secret(v_id, '$STAGING_URL'); end if;
     end \$\$" >/dev/null
GOT=$(sql "select decrypted_secret as u from vault.decrypted_secrets where name = 'functions_base_url'" | jq -r '.[0].u')
[ "$GOT" = "$STAGING_URL" ] || { echo "  FAIL: the Vault secret is '$GOT'"; exit 1; }
echo "   ok: $GOT"

# ---- 2. Edge Functions
echo "2. Edge Functions"
for f in agora-token invite-staff ghost-admin admin-update-staff-auth request-account-deletion send-push; do
  flags="--use-api"
  case "$f" in send-push|request-account-deletion) flags="$flags --no-verify-jwt";; esac
  supabase functions deploy "$f" --project-ref "$STAGING_REF" --workdir "$WORK" $flags 2>&1 | grep -E "Deployed|Error|error" | head -2 | sed "s/^/   $f: /"
done

# ---- 3. the secret send-push checks (the database signs its calls with the same value)
echo "3. send-push secret"
PUSH_SECRET=$(sql "select decrypted_secret as s from vault.decrypted_secrets where name = 'push_internal_secret'" | jq -r '.[0].s')
[ -n "$PUSH_SECRET" ] && [ "$PUSH_SECRET" != "null" ] || { echo "  FAIL: no push_internal_secret in staging Vault"; exit 1; }
supabase secrets set PUSH_INTERNAL_SECRET="$PUSH_SECRET" --project-ref "$STAGING_REF" >/dev/null 2>&1 && echo "   ok (value not shown)"

# ---- 4. catalog data, and no demo codes
echo "4. catalog data"
if [ "$(sql 'select count(*) as n from public.gifts' | jq -r '.[0].n')" = "0" ]; then
  # absolute path: with --workdir a relative path would be looked up inside the staging folder
  if OUT=$(supabase db query --linked --workdir "$WORK" -o json -f "$PWD/supabase/seed.sql" 2>&1); then echo "   seed.sql loaded"
  else echo "   FAIL: seed.sql: $(echo "$OUT" | tail -2 | tr '\n' ' ' | cut -c1-300)"; exit 1; fi
else echo "   already loaded"; fi
sql "delete from public.host_codes where code = 'SABADEMO'; delete from public.reseller_codes where code = 'RESELL01'" >/dev/null || true

# ---- 5. fake accounts
echo "5. fake test accounts"
if ! grep -q '^STAGING_TEST_PASSWORD=' "$ENV_FILE"; then
  printf 'STAGING_TEST_PASSWORD=%s\n' "$(openssl rand -base64 18 | tr -d '/+=\n' | cut -c1-14)Aa9!" >> "$ENV_FILE"
fi
set -a; . "$ENV_FILE"; set +a
SERVICE_KEY=$(supabase projects api-keys --project-ref "$STAGING_REF" -o json 2>/dev/null | jq -r '.[] | select(.name == "service_role") | .api_key')
[ -n "$SERVICE_KEY" ] || { echo "  FAIL: could not read the staging service key"; exit 1; }
DOMAIN="staging.sabalive.test"
make_user() {   # email username display-name
  local code
  code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$STAGING_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1@$DOMAIN\",\"password\":\"$STAGING_TEST_PASSWORD\",\"email_confirm\":true,\"user_metadata\":{\"name\":\"$3\",\"username\":\"$2\"}}")
  case "$code" in 200|201) echo "   created $1@$DOMAIN";; 422) echo "   exists  $1@$DOMAIN";; *) echo "   FAIL ($code) $1@$DOMAIN";; esac
}
make_user superadmin stg_superadmin "Staging Super Admin"
make_user master stg_master "Staging Master"
for i in 1 2 3; do make_user "host$i" "stg_host$i" "Staging Host $i"; done
for i in 1 2 3 4 5 6 7 8 9 10; do make_user "user$i" "stg_user$i" "Staging User $i"; done
unset SERVICE_KEY

sql "insert into public.staff_roles (user_id, role) select id, 'super_admin' from auth.users where email = 'superadmin@$DOMAIN'
       and not exists (select 1 from public.staff_roles s where s.user_id = auth.users.id);
     insert into public.staff_roles (user_id, role) select id, 'admin' from auth.users where email = 'master@$DOMAIN'
       and not exists (select 1 from public.staff_roles s where s.user_id = auth.users.id);
     update public.profiles set is_host = true where id in (select id from auth.users where email like 'host%@$DOMAIN');
     insert into public.host_profiles (profile_id) select id from auth.users where email like 'host%@$DOMAIN'
       and not exists (select 1 from public.host_profiles h where h.profile_id = auth.users.id);
     insert into public.host_grants (profile_id) select id from auth.users where email like 'host%@$DOMAIN'
       and not exists (select 1 from public.host_grants g where g.profile_id = auth.users.id);
     insert into public.wallet_ledger (profile_id, kind, currency, amount, note)
       select u.id, 'grant', 'coins', 50000, 'staging seed' from auth.users u
        where (u.email like 'host%@$DOMAIN' or u.email like 'user%@$DOMAIN')
          and not exists (select 1 from public.wallet_ledger l where l.profile_id = u.id and l.note = 'staging seed')" >/dev/null
echo "   roles, host access and starting coins set"

echo
echo "STAGING READY: $STAGING_URL"
echo "  Panel / app logins: superadmin@$DOMAIN, master@$DOMAIN (panel); host1-3@$DOMAIN, user1-10@$DOMAIN (app)"
echo "  Password: STAGING_TEST_PASSWORD in $ENV_FILE"
echo "  Still to do by you: Agora + FCM secrets, Auth dashboard settings (docs/STAGING.md)."
