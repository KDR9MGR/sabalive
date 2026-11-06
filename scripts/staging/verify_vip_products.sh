#!/usr/bin/env bash
# Checks the VIP products (migration 20261106120000) on STAGING through the same REST calls the panel and the app make, signed in as the fake Master and a fake user
# (never production, never real people). It creates ONE test product for 1 coin, buys it as a user, reads it every way the app / panel does, then deletes it.
#
#   scripts/staging/verify_vip_products.sh
#
# Reads ~/sabalive-secrets/staging.env (STAGING_URL, STAGING_PUBLISHABLE_KEY, STAGING_TEST_PASSWORD). Prints PASS / FAIL per step; nothing secret is printed.
set -uo pipefail
cd "$(dirname "$0")/../.."
command -v curl >/dev/null || { echo "curl not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }

ENV_FILE="${STAGING_ENV_FILE:-$HOME/sabalive-secrets/staging.env}"
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. See docs/STAGING.md."; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${STAGING_URL:?}" "${STAGING_PUBLISHABLE_KEY:?}" "${STAGING_TEST_PASSWORD:?}"
PROD=$(grep -E "static const String productionUrl" lib/config/supabase_config.dart | grep -oE 'https://[a-z0-9]+\.supabase\.co')
[ "$STAGING_URL" != "$PROD" ] || { echo "STAGING_URL is the production address. Refusing."; exit 2; }
DOMAIN="staging.sabalive.test"

FAILED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s%s\n' "$1" "${2:+  <- $2}"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "true" ]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

login() {   # email -> access token
  curl -s -m 20 -X POST "$STAGING_URL/auth/v1/token?grant_type=password" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1@$DOMAIN\",\"password\":\"$STAGING_TEST_PASSWORD\"}" | jq -r '.access_token // empty'
}
api() {     # token method path [json body]
  local tok="$1" method="$2" path="$3" body="${4:-}"
  curl -s -m 30 -X "$method" "$STAGING_URL/rest/v1/$path" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $tok" \
    -H 'Content-Type: application/json' ${body:+-d "$body"}
}

echo "VIP products check on STAGING ($STAGING_URL)  $(date -u +%Y-%m-%d\ %H:%M:%S) UTC"
MASTER=$(login master); USER=$(login user1)
[ -n "$MASTER" ] && pass "signed in as the fake Master" || { fail "sign in as the fake Master"; exit 1; }
[ -n "$USER" ] && pass "signed in as a fake user" || { fail "sign in as a fake user"; exit 1; }
USER_ID=$(curl -s -m 20 "$STAGING_URL/auth/v1/user" -H "apikey: $STAGING_PUBLISHABLE_KEY" -H "Authorization: Bearer $USER" | jq -r '.id')

# 1. a plain user cannot create a product
R=$(api "$USER" POST rpc/admin_save_vip_product '{"p_id":null,"p_name":"Sneaky","p_tagline":null,"p_badge_url":null,"p_price":1,"p_days":1,"p_status":"active","p_sort":0,"p_benefits":[]}')
check "a plain user cannot create a VIP product" "$(echo "$R" | jq -r '(.message // "") | test("Only a Master or Super Admin")')" "$R"

# 2. the Master creates a test product (a fixed kind, a custom one, and a link to a real Store item when staging has one)
ITEM=$(api "$MASTER" GET "store_items?select=id&category=eq.entry_effect&limit=1" | jq -r '.[0].id // empty')
BENEFITS='[{"kind":"identity"},{"kind":"anti_kick"},{"kind":"custom","title":"Test custom"}]'
[ -n "$ITEM" ] && BENEFITS=$(echo "$BENEFITS" | jq -c --arg i "$ITEM" '. + [{"kind":"entry_effect","link_item_id":$i}]')
PID=$(api "$MASTER" POST rpc/admin_save_vip_product "$(jq -nc --argjson b "$BENEFITS" '{p_id:null,p_name:"zz-verify VIP",p_tagline:"staging check",p_badge_url:null,p_price:1,p_days:30,p_status:"active",p_sort:999,p_benefits:$b}')" | jq -r 'if type=="string" then . else empty end')
check "the Master created a test product" "$([ -n "$PID" ] && echo true || echo false)"
[ -n "$PID" ] || { echo "RESULT: $FAILED FAILED"; exit 1; }

# 3. the panel's list query (benefits + the count of people who own it now)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
R=$(api "$MASTER" GET "vip_products?select=id,name,tagline,badge_url,price_coins,duration_days,status,sort_order,vip_product_benefits(id,kind,title,image_url,link_item_id,sort_order),user_vip(count)&user_vip.expires_at=gt.$NOW&id=eq.$PID")
check "the panel's list read works and shows the product with its benefits and an owners count" \
  "$(echo "$R" | jq -r --argjson n "$(echo "$BENEFITS" | jq 'length')" 'length == 1 and (.[0].vip_product_benefits | length) == $n and (.[0].user_vip[0].count == 0)')" "$R"

# 4. the app's list query (active only, benefits embedded, in order)
R=$(api "$USER" GET "vip_products?select=id,name,tagline,badge_url,price_coins,duration_days,sort_order,vip_product_benefits(id,kind,title,image_url,link_item_id,sort_order)&status=eq.active&order=sort_order&order=price_coins")
check "a user's list read shows the active test product with its benefits" \
  "$(echo "$R" | jq -r --arg p "$PID" 'any(.[]; .id == $p and (.vip_product_benefits | length) >= 3)')" "$R"

# 5. buy it
BEFORE=$(api "$USER" GET "wallets?select=coins&profile_id=eq.$USER_ID" | jq -r '.[0].coins')
R=$(api "$USER" POST rpc/purchase_vip_product "{\"p_product_id\":\"$PID\"}")
check "the user bought it: the answer carries product_id and expires_at" "$(echo "$R" | jq -r --arg p "$PID" '.product_id == $p and (.expires_at | type) == "string" and .price_coins == 1')" "$R"
AFTER=$(api "$USER" GET "wallets?select=coins&profile_id=eq.$USER_ID" | jq -r '.[0].coins')
check "exactly 1 coin was taken" "$([ "$((BEFORE - AFTER))" = "1" ] && echo true || echo false)" "$BEFORE -> $AFTER"

# 6. what the app reads afterwards: ownership and the profile badge
R=$(api "$USER" GET "user_vip?select=product_id,expires_at&profile_id=eq.$USER_ID&expires_at=gt.$NOW")
check "the app's 'what do I own' read shows the product" "$(echo "$R" | jq -r --arg p "$PID" 'any(.[]; .product_id == $p)')" "$R"
R=$(api "$USER" GET "user_vip?select=expires_at,vip_products!inner(name,badge_url,price_coins)&profile_id=eq.$USER_ID&expires_at=gt.$NOW")
check "the profile badge read works (product name and price through the join)" "$(echo "$R" | jq -r 'any(.[]; .vip_products.name == "zz-verify VIP" and .vip_products.price_coins == 1)')" "$R"
if [ -n "$ITEM" ]; then
  R=$(api "$USER" GET "user_items?select=item_id,equipped,expires_at&profile_id=eq.$USER_ID&item_id=eq.$ITEM")
  check "the linked Store item is in the buyer's Bag" "$(echo "$R" | jq -r 'length >= 1')" "$R"
fi

# 7. buying again adds days
E1=$(api "$USER" GET "user_vip?select=expires_at&profile_id=eq.$USER_ID&product_id=eq.$PID" | jq -r '.[0].expires_at')
api "$USER" POST rpc/purchase_vip_product "{\"p_product_id\":\"$PID\"}" >/dev/null
E2=$(api "$USER" GET "user_vip?select=expires_at&profile_id=eq.$USER_ID&product_id=eq.$PID" | jq -r '.[0].expires_at')
check "buying again extended the days (the second end is 30 days after the first)" "$(jq -nr --arg a "$E1" --arg b "$E2" 'def t: sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdate; (($b | t) - ($a | t)) == 2592000')" "$E1 -> $E2"

# 8. a hidden product is hidden from users, and a user cannot write
api "$MASTER" POST rpc/admin_save_vip_product "$(jq -nc --arg id "$PID" --argjson b "$BENEFITS" '{p_id:$id,p_name:"zz-verify VIP",p_tagline:"staging check",p_badge_url:null,p_price:1,p_days:30,p_status:"inactive",p_sort:999,p_benefits:$b}')" >/dev/null
R=$(api "$USER" GET "vip_products?select=id&id=eq.$PID")
check "set to Inactive, the product is hidden from the user" "$(echo "$R" | jq -r 'length == 0')" "$R"
R=$(api "$USER" POST rpc/purchase_vip_product "{\"p_product_id\":\"$PID\"}")
check "and it cannot be bought while hidden" "$(echo "$R" | jq -r '(.message // "") | test("not available")')" "$R"
R=$(api "$USER" PATCH "user_vip?profile_id=eq.$USER_ID" '{"expires_at":"2099-01-01T00:00:00Z"}')
E3=$(api "$USER" GET "user_vip?select=expires_at&profile_id=eq.$USER_ID&product_id=eq.$PID" | jq -r '.[0].expires_at')
check "a user cannot change their own VIP days" "$([ "${E3:0:4}" != "2099" ] && echo true || echo false)" "$R"

# 9. clean up: the Master deletes the test product (the owners count comes back), and nothing is left behind
N=$(api "$MASTER" POST rpc/admin_delete_vip_product "{\"p_id\":\"$PID\"}")
check "the Master deleted the test product (it reports its owner)" "$([ "$N" = "1" ] || [ "$N" = "0" ] && echo true || echo false)" "$N"
LEFT=$(api "$MASTER" GET "vip_products?select=id&name=eq.zz-verify%20VIP" | jq -r 'length')
check "nothing is left behind" "$([ "$LEFT" = "0" ] && echo true || echo false)" "$LEFT"

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: ALL PASSED"; else echo "RESULT: $FAILED FAILED"; exit 1; fi
