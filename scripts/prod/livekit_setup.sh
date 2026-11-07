#!/usr/bin/env bash
# PRODUCTION: MS cloud (the hosted LiveKit server, "LiveCore") for the live project: its three secrets and the `livekit-token` function.
#
#   scripts/prod/livekit_setup.sh --check                                     read-only: is the function deployed and alive? (never shows a secret)
#   scripts/prod/livekit_setup.sh --secrets                                   DRY RUN: checks your file and says what it WOULD set (names only)
#   LIVEKIT_CONFIRM=<project ref> scripts/prod/livekit_setup.sh --secrets --apply     sets LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET on production
#   LIVEKIT_CONFIRM=<project ref> scripts/prod/livekit_setup.sh --deploy  --apply     deploys the livekit-token function to production
#
# The values live ONLY in ~/sabalive-secrets/livekit-prod.env (outside git, mode 600), three lines you make yourself, never pasted in chat:
#     LIVEKIT_URL=wss://<name>.livecore.cloud
#     LIVEKIT_API_KEY=...
#     LIVEKIT_API_SECRET=...
# (the vendor's own names LIVECORE_URL / LIVECORE_API_KEY / LIVECORE_API_SECRET work too). Nothing is printed except names, and the secrets go to Supabase through a
# short-lived private file, not the command line. It refuses to run unless the repo's Supabase link folder really is production, and refuses a file that holds the
# STAGING pair. Setting the secrets does NOT turn MS cloud on for anybody: that is the switch "MS cloud for new lives" in the panel's Release controls (off by default).
# Run `--apply` only after the owner says "go" (root CLAUDE.md > Production safety).
set -uo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/supabase_login.sh
command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }

PROD_URL=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE 'https://[a-z0-9]+\.supabase\.co')
PROD_REF=$(echo "$PROD_URL" | sed -E 's#https://([a-z0-9]+)\..*#\1#')
LINKED=$(cat supabase/.temp/project-ref 2>/dev/null || echo unknown)
FILE="${LIVEKIT_PROD_ENV_FILE:-$HOME/sabalive-secrets/livekit-prod.env}"
STAGING_FILE="${LIVEKIT_ENV_FILE:-$HOME/sabalive-secrets/livekit-staging.env}"

MODE="${1:-}"; shift || true
APPLY=0; for a in "$@"; do [ "$a" = "--apply" ] && APPLY=1; done

load() { # prints nothing; sets LK_URL / LK_KEY / LK_SECRET from a file (either naming)
  ( set -a; . "$1" >/dev/null 2>&1; set +a
    printf '%s\n%s\n%s\n' "${LIVEKIT_URL:-${LIVECORE_URL:-}}" "${LIVEKIT_API_KEY:-${LIVECORE_API_KEY:-}}" "${LIVEKIT_API_SECRET:-${LIVECORE_API_SECRET:-}}" )
}

case "$MODE" in
  --check)
    code=$(curl -s -m 20 -o /tmp/lk_prod_check.json -w '%{http_code}' -X POST "$PROD_URL/functions/v1/livekit-token" -H "apikey: $(grep -E "_productionKey = " lib/config/supabase_config.dart | grep -oE 'sb_publishable_[A-Za-z0-9_-]+')" -H 'Content-Type: application/json' -d '{}')
    echo "production livekit-token: HTTP $code  $(head -c 160 /tmp/lk_prod_check.json | tr '\n' ' ')"
    rm -f /tmp/lk_prod_check.json
    case "$code" in
      401) echo "  alive: it answers and wants a signed-in user (that is the healthy answer)";;
      404) echo "  NOT deployed on production yet";;
      *)   echo "  unexpected answer: look at it before going on";;
    esac
    ;;
  --secrets|--deploy)
    [ "$LINKED" = "$PROD_REF" ] || { echo "Refusing: this repo's Supabase link folder is '$LINKED', not production ($PROD_REF). Run it from the app repo linked to production."; exit 2; }
    if [ "$MODE" = "--secrets" ]; then
      [ -f "$FILE" ] || { echo "Missing $FILE. Make it yourself (chmod 600) with the three lines named at the top of this script, values from your LiveCore account."; exit 2; }
      perm=$(stat -f '%Lp' "$FILE" 2>/dev/null || stat -c '%a' "$FILE")
      [ "$perm" = "600" ] || { echo "$FILE must be mode 600 (chmod 600 $FILE)."; exit 2; }
      mapfile -t V < <(load "$FILE") 2>/dev/null || { V=(); while IFS= read -r l; do V+=("$l"); done < <(load "$FILE"); }
      LK_URL="${V[0]:-}"; LK_KEY="${V[1]:-}"; LK_SECRET="${V[2]:-}"
      [ -n "$LK_URL" ] && [ -n "$LK_KEY" ] && [ -n "$LK_SECRET" ] || { echo "$FILE must define LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET."; exit 2; }
      case "$LK_URL" in wss://*) ;; *) echo "LIVEKIT_URL must start with wss://"; exit 2;; esac
      if [ -f "$STAGING_FILE" ]; then
        mapfile -t S < <(load "$STAGING_FILE") 2>/dev/null || { S=(); while IFS= read -r l; do S+=("$l"); done < <(load "$STAGING_FILE"); }
        if [ -n "${S[1]:-}" ] && [ "${S[1]}" = "$LK_KEY" ]; then echo "Refusing: the API key in $FILE is the same as the STAGING key. Production needs its own pair."; exit 2; fi
      fi
      echo "production project: $PROD_REF"
      echo "file ok: $FILE (mode 600)"
      echo "would set: LIVEKIT_URL (host $(echo "$LK_URL" | sed -E 's#wss://([^/]+).*#\1#')), LIVEKIT_API_KEY ($(printf %s "$LK_KEY" | wc -c | tr -d ' ') characters), LIVEKIT_API_SECRET ($(printf %s "$LK_SECRET" | wc -c | tr -d ' ') characters)"
      if [ "$APPLY" -ne 1 ]; then echo "(dry run: nothing was changed. To set them: LIVEKIT_CONFIRM=$PROD_REF $0 --secrets --apply)"; exit 0; fi
      [ "${LIVEKIT_CONFIRM:-}" = "$PROD_REF" ] || { echo "Refusing: type LIVEKIT_CONFIRM=$PROD_REF on purpose (only after the owner said go)."; exit 2; }
      tmp=$(mktemp); chmod 600 "$tmp"; trap 'rm -f "$tmp"' EXIT
      printf 'LIVEKIT_URL=%s\nLIVEKIT_API_KEY=%s\nLIVEKIT_API_SECRET=%s\n' "$LK_URL" "$LK_KEY" "$LK_SECRET" > "$tmp"
      if supabase secrets set --env-file "$tmp" --project-ref "$PROD_REF" >/dev/null 2>&1; then
        echo "ok: the three MS cloud secrets are set on PRODUCTION (values not shown). MS cloud is still OFF for everybody: the panel switch decides."
      else echo "FAILED to set the secrets (wrong login? run: supabase projects list)"; exit 1; fi
    else
      echo "production project: $PROD_REF   function: livekit-token (the agora-token function is not touched)"
      if [ "$APPLY" -ne 1 ]; then echo "(dry run: nothing was deployed. To deploy: LIVEKIT_CONFIRM=$PROD_REF $0 --deploy --apply)"; exit 0; fi
      [ "${LIVEKIT_CONFIRM:-}" = "$PROD_REF" ] || { echo "Refusing: type LIVEKIT_CONFIRM=$PROD_REF on purpose (only after the owner said go)."; exit 2; }
      supabase functions deploy livekit-token --project-ref "$PROD_REF" --use-api 2>&1 | grep -E "Deployed|Error|error|WARN" | head -5
    fi
    ;;
  *) sed -n 2,6p "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
