#!/usr/bin/env bash
# Runs the Edge Function unit tests that do not need Deno (Node's test runner; Node 22.6+ understands .ts).
#   scripts/test_functions.sh
# It installs node-forge (the one dependency) into a temporary folder, never into the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v node >/dev/null || { echo "node not found"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
( cd "$TMP" && npm init -y >/dev/null 2>&1 && npm install node-forge@1.3.1 --no-audit --no-fund --silent )
# the function imports "node-forge" by name (a Deno import map); point that name at a tiny shim over the temporary copy
cat > "$TMP/forge-shim.mjs" <<SHIM
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
export default require('./node_modules/node-forge');
SHIM
cat > "$TMP/hooks.mjs" <<HOOKS
export async function resolve(specifier, context, next) {
  if (specifier === 'node-forge') return { url: 'file://$TMP/forge-shim.mjs', format: 'module', shortCircuit: true };
  return next(specifier, context);
}
HOOKS
cat > "$TMP/register.mjs" <<REG
import { register } from 'node:module';
register('file://$TMP/hooks.mjs');
REG
node --import "file://$TMP/register.mjs" --test supabase/functions/*/*.test.ts
