#!/usr/bin/env bash
# Build the signed Play bundle (.aab) and check it really is a production build.
#
#   scripts/release/build_play_bundle.sh                 # build + verify + save a copy
#   scripts/release/build_play_bundle.sh --verify-only FILE.aab     # just check an existing bundle
#
# It does NOT change the version: set `version:` in pubspec.yaml yourself first (the +N must be higher
# than the last upload). It refuses to build with staging flags in the environment, and after building it
# checks that
#   - the bundle is signed with the release key in signer.sha256 (Gradle quietly falls back to the DEBUG key
#     when the keystore file is missing, which Play rejects),
#   - the only Supabase address compiled into the app is the production one (never a staging build).
# The result is saved as ~/sabalive-releases/sabalive-<version>-release.aab (an existing file is never overwritten).
set -euo pipefail
cd "$(dirname "$0")/../.."    # sabalive/

PROD_URL=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE 'https://[a-z0-9]+\.supabase\.co')
EXPECTED_SIGNER=$(tr -d ' \n' < scripts/release/signer.sha256)
DEST_DIR="${SABALIVE_RELEASES_DIR:-$HOME/sabalive-releases}"

verify_bundle() {
  local aab="$1" ok=0
  [ -f "$aab" ] || { echo "No such file: $aab"; return 1; }
  echo "Verifying $aab"

  local signer fp
  signer=$(keytool -printcert -jarfile "$aab" 2>/dev/null | grep -m1 'Owner:' | sed 's/^Owner: //')
  fp=$(keytool -printcert -jarfile "$aab" 2>/dev/null | grep -m1 'SHA256:' | sed 's/.*SHA256: *//' | tr -d ' \n')
  if [ "$fp" = "$EXPECTED_SIGNER" ]; then echo "  PASS  signed with the release key ($signer)"
  else echo "  FAIL  signer is '$signer' ($fp), expected the release key $EXPECTED_SIGNER. Is /Users/abdulrazak/sabalive-secrets/android/key.properties present?"; ok=1; fi

  local tmp urls
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  unzip -q -o "$aab" 'base/lib/*/libapp.so' -d "$tmp" 2>/dev/null || true
  urls=$(for f in "$tmp"/base/lib/*/libapp.so; do [ -f "$f" ] && strings -a "$f"; done | grep -oE 'https://[a-z0-9]+\.supabase\.co' | sort -u)
  if [ "$urls" = "$PROD_URL" ]; then echo "  PASS  the only Supabase address inside the app is production ($PROD_URL)"
  elif [ -z "$urls" ]; then echo "  FAIL  could not find any Supabase address inside the app (is this an app bundle?)"; ok=1
  else echo "  FAIL  the app contains other Supabase addresses: $(echo $urls | tr '\n' ' ')"; ok=1; fi
  return $ok
}

if [ "${1:-}" = "--verify-only" ]; then
  verify_bundle "${2:?give the .aab to check}" && echo "RESULT: OK" || { echo "RESULT: FAILED"; exit 1; }
  exit 0
fi

# --- build -------------------------------------------------------------------------------------------
if [ -n "${SABALIVE_ENV:-}${SUPABASE_URL:-}${SUPABASE_PUBLISHABLE_KEY:-}" ]; then
  echo "Refusing: SABALIVE_ENV / SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY is set in your shell. A Play build must use none."; exit 2
fi
VERSION=$(grep -E '^version:' pubspec.yaml | awk '{print $2}')
DEST="$DEST_DIR/sabalive-$VERSION-release.aab"
mkdir -p "$DEST_DIR"
if [ -e "$DEST" ] && [ "${FORCE:-}" != "1" ]; then
  echo "Refusing: $DEST already exists (that version was built before). Bump the +N in pubspec.yaml, or FORCE=1 to overwrite."; exit 2
fi
echo "Building $VERSION"
echo "Note: close other Flutter / IDE windows first. On a machine with little memory the shrinker (R8) fails."
if git diff --quiet && git diff --cached --quiet; then echo "  git: working tree clean"; else echo "  WARNING: uncommitted changes will be in this build"; fi

# `flutter clean` first: a stale generated plugin file (left behind by `flutter test` / `analyze`, which
# include dev-only plugins) makes the release compile fail with "package ... does not exist".
flutter clean >/dev/null
flutter build appbundle --release
AAB="build/app/outputs/bundle/release/app-release.aab"
[ -f "$AAB" ] || { echo "Build produced no bundle"; exit 1; }

if verify_bundle "$AAB"; then
  cp "$AAB" "$DEST"
  echo
  echo "RESULT: OK"
  echo "  $DEST"
  echo "  size   $(du -h "$DEST" | cut -f1)"
  echo "  sha256 $(shasum -a 256 "$DEST" | cut -d' ' -f1)"
  echo "  version $VERSION  (the +N is the Play versionCode; it must be higher than the last upload)"
else
  echo "RESULT: FAILED. Do not upload this bundle."; exit 1
fi
