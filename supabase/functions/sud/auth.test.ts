import test from "node:test";
import assert from "node:assert/strict";
import { CODE_TTL_MS, hmacHex, mintToken, safeEqual, sdkErrorCode, signToken, verifyToken } from "./auth.ts";

const SECRET = "test-secret-not-real";
const APP = "1000000000000000001";
const NOW = 1_800_000_000_000;

test("a minted code reads back: uid, app, kind, and an expiry in seconds", async () => {
  const m = await mintToken({ secret: SECRET, appId: APP, kind: "code", uid: "u-1", ttlMs: CODE_TTL_MS, nowMs: NOW });
  assert.equal(m.expireDate, NOW + CODE_TTL_MS);
  const v = await verifyToken(SECRET, APP, "code", m.token, NOW + 1000);
  assert.equal(v.ok, true);
  if (v.ok) {
    assert.equal(v.claims.uid, "u-1");
    assert.equal(v.claims.app_id, APP);
    assert.equal(v.claims.exp, Math.floor((NOW + CODE_TTL_MS) / 1000));
  }
});

test("the token is the JWT SUD's own tools expect: three parts, HS256, claims uid / exp / app_id", async () => {
  const m = await mintToken({ secret: SECRET, appId: APP, kind: "code", uid: "123", ttlMs: 3600000, nowMs: NOW });
  const [h, p] = m.token.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url").toString()), { alg: "HS256", typ: "JWT" });
  const claims = JSON.parse(Buffer.from(p, "base64url").toString());
  assert.equal(claims.uid, "123");
  assert.equal(claims.app_id, APP);
  assert.equal(typeof claims.exp, "number");
});

test("an expired token is refused with SUD's expired code 1005", async () => {
  const m = await mintToken({ secret: SECRET, appId: APP, kind: "ss", uid: "u", ttlMs: 1000, nowMs: NOW });
  const v = await verifyToken(SECRET, APP, "ss", m.token, NOW + 5000);
  assert.deepEqual(v, { ok: false, error: "expired" });
  assert.equal(sdkErrorCode("expired"), 1005);
});

test("a token signed with another secret, or edited, is refused (1002)", async () => {
  const m = await mintToken({ secret: "other", appId: APP, kind: "ss", uid: "u", ttlMs: 60000, nowMs: NOW });
  assert.deepEqual(await verifyToken(SECRET, APP, "ss", m.token, NOW), { ok: false, error: "verify" });
  const good = await mintToken({ secret: SECRET, appId: APP, kind: "ss", uid: "u", ttlMs: 60000, nowMs: NOW });
  const [h, , s] = good.token.split(".");
  const forged = `${h}.${Buffer.from(JSON.stringify({ uid: "admin", exp: 9999999999, app_id: APP, k: "ss" })).toString("base64url")}.${s}`;
  assert.deepEqual(await verifyToken(SECRET, APP, "ss", forged, NOW), { ok: false, error: "verify" });
  assert.equal(sdkErrorCode("verify"), 1002);
});

test("a code is not an ss token and the other way round; another app's token is invalid (1004)", async () => {
  const code = await mintToken({ secret: SECRET, appId: APP, kind: "code", uid: "u", ttlMs: 60000, nowMs: NOW });
  assert.deepEqual(await verifyToken(SECRET, APP, "ss", code.token, NOW), { ok: false, error: "invalid" });
  const ss = await mintToken({ secret: SECRET, appId: APP, kind: "ss", uid: "u", ttlMs: 60000, nowMs: NOW });
  assert.deepEqual(await verifyToken(SECRET, APP, "code", ss.token, NOW), { ok: false, error: "invalid" });
  const foreign = await mintToken({ secret: SECRET, appId: "999", kind: "code", uid: "u", ttlMs: 60000, nowMs: NOW });
  assert.deepEqual(await verifyToken(SECRET, APP, "code", foreign.token, NOW), { ok: false, error: "invalid" });
  assert.equal(sdkErrorCode("invalid"), 1004);
});

test("junk is unreadable (1003), and a token with alg none is refused", async () => {
  for (const junk of ["", "abc", "a.b", "a.b.c.d", undefined, null, 5, "x".repeat(5000)]) {
    const v = await verifyToken(SECRET, APP, "code", junk, NOW);
    assert.equal(v.ok, false, String(junk));
  }
  assert.equal(sdkErrorCode("decode"), 1003);
  const none = `${Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url")}.${Buffer.from(JSON.stringify({ uid: "u", exp: 9999999999, app_id: APP, k: "code" })).toString("base64url")}.`;
  assert.equal((await verifyToken(SECRET, APP, "code", none, NOW)).ok, false);
});

test("extra claims ride along (the launch token carries the game and room)", async () => {
  const m = await mintToken({ secret: SECRET, appId: APP, kind: "launch", uid: "u", ttlMs: 60000, nowMs: NOW, extra: { mg: "123", room: "r1" } });
  const v = await verifyToken(SECRET, APP, "launch", m.token, NOW);
  assert.equal(v.ok && v.claims.mg, "123");
  assert.equal(v.ok && v.claims.room, "r1");
});

test("safeEqual and the HMAC helper", async () => {
  assert.equal(safeEqual("abc", "abc"), true);
  assert.equal(safeEqual("abc", "abd"), false);
  assert.equal(safeEqual("abc", "abcd"), false);
  assert.equal(await hmacHex("SHA-1", "key", "The quick brown fox jumps over the lazy dog"), "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9");
  assert.equal(await hmacHex("SHA-256", "key", "The quick brown fox jumps over the lazy dog"), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
});

test("signToken is deterministic for the same claims", async () => {
  const claims = { uid: "u", exp: 1900000000, app_id: APP, k: "code" as const };
  assert.equal(await signToken(SECRET, claims), await signToken(SECRET, claims));
});
