import test from "node:test";
import assert from "node:assert/strict";
import { signatureString, sudSignature, verifySudRequest } from "./signature.ts";

const SECRET = "test-secret-not-real";
const APP = "1461564080052506638";
const NOW = 1_800_000_000_000;
const BODY = '{"order_id":"o1","uid":"u","score":5,"type":1}';
const hdrs = (o: Record<string, string>) => ({ get: (n: string) => o[n.toLowerCase()] ?? null });

test("the signature string is the four lines of the docs, each ending in a newline, the last too", () => {
  assert.equal(signatureString("1", "2", "3", "4"), "1\n2\n3\n4\n");
});

test("HMAC-SHA1 hex of that string with the app secret (what SUD's Node example computes)", async () => {
  const { createHmac } = await import("node:crypto");
  const expected = createHmac("sha1", SECRET).update(`${APP}\n${String(NOW)}\nabcDEF\n${BODY}\n`).digest("hex");
  assert.equal(await sudSignature(SECRET, APP, String(NOW), "abcDEF", BODY), expected);
});

test("a correctly signed request is valid; headers are case-insensitive", async () => {
  const sig = await sudSignature(SECRET, APP, String(NOW), "n1", BODY);
  const r = await verifySudRequest({ secret: SECRET, appId: APP, body: BODY, nowMs: NOW + 1000, headers: hdrs({ "sud-appid": APP, "sud-timestamp": String(NOW), "sud-nonce": "n1", "sud-signature": sig }) });
  assert.deepEqual(r, { present: true, valid: true });
  const upper = await verifySudRequest({ secret: SECRET, appId: APP, body: BODY, nowMs: NOW, headers: hdrs({ "sud-appid": APP, "sud-timestamp": String(NOW), "sud-nonce": "n1", "sud-signature": sig.toUpperCase() }) });
  assert.equal(upper.valid, true);
});

test("seconds are understood as well as milliseconds", async () => {
  const secs = String(Math.floor(NOW / 1000));
  const sig = await sudSignature(SECRET, APP, secs, "n", BODY);
  const r = await verifySudRequest({ secret: SECRET, appId: APP, body: BODY, nowMs: NOW, headers: hdrs({ "sud-appid": APP, "sud-timestamp": secs, "sud-nonce": "n", "sud-signature": sig }) });
  assert.equal(r.valid, true);
});

test("a changed body, a wrong secret, a wrong app and a stale timestamp are all refused", async () => {
  const sig = await sudSignature(SECRET, APP, String(NOW), "n1", BODY);
  const base = { "sud-appid": APP, "sud-timestamp": String(NOW), "sud-nonce": "n1", "sud-signature": sig };
  assert.equal((await verifySudRequest({ secret: SECRET, appId: APP, body: BODY + " ", nowMs: NOW, headers: hdrs(base) })).valid, false);
  assert.equal((await verifySudRequest({ secret: "other", appId: APP, body: BODY, nowMs: NOW, headers: hdrs(base) })).valid, false);
  assert.equal((await verifySudRequest({ secret: SECRET, appId: "999", body: BODY, nowMs: NOW, headers: hdrs(base) })).reason, "wrong app");
  assert.equal((await verifySudRequest({ secret: SECRET, appId: APP, body: BODY, nowMs: NOW + 3 * 3600 * 1000, headers: hdrs(base) })).reason, "stale timestamp");
});

test("no signature header means present = false (the caller decides what that is worth)", async () => {
  const r = await verifySudRequest({ secret: SECRET, appId: APP, body: BODY, nowMs: NOW, headers: hdrs({}) });
  assert.deepEqual(r, { present: false, valid: false, reason: "no signature" });
});
