#!/usr/bin/env bash
# Puts ONE saved SUD verification body on the clipboard, without printing it:  scripts/prod/sud_copy_body.sh get_sstoken|update_sstoken|report_game_info|notify
# (made by scripts/prod/sud_verification_bodies.sh; paste it into the BODY box of the console's dialog).
set -euo pipefail
FILE="${SUD_VERIFICATION_FILE:-$HOME/sabalive-secrets/sud_verification.json}"
NAME="${1:-}"
case "$NAME" in get_sstoken|update_sstoken|report_game_info|notify) ;; *) echo "usage: $0 get_sstoken|update_sstoken|report_game_info|notify"; exit 2;; esac
[ -f "$FILE" ] || { echo "No saved bodies: run scripts/prod/sud_verification_bodies.sh first"; exit 1; }
EXP=$(jq -r .expires_at "$FILE"); [ "$(date -u +%s)" -lt "$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${EXP%%.*}" +%s 2>/dev/null || echo 0)" ] || { echo "The saved bodies have expired: run scripts/prod/sud_verification_bodies.sh again"; exit 1; }
jq -c ".$NAME" "$FILE" | tr -d '\n' | pbcopy
echo "Copied the $NAME body ($(jq -c ".$NAME" "$FILE" | wc -c | tr -d ' ') characters) to the clipboard."
