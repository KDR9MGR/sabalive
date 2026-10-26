import test from "node:test";
import assert from "node:assert/strict";
import { buildLaunch, refreshCode, sudLanguage } from "./launch.ts";
import { verifyToken } from "./auth.ts";

const NOW = 1_800_000_000_000;
const deps = { secret: "s3cret-not-real", appId: "1000000000000000001", appKey: "client-key", pageUrl: "https://sabalive.in/sud/play", apiBase: "https://abc.supabase.co/functions/v1/sud", testEnv: true, now: () => NOW };
const check = { ok: true, mg_id: "1468180338417074177", uid: "b1000000-0000-0000-0000-0000000000b2", room_id: "live-123", uses_coins: false, aspect: 1, name: "Ludo" };

test("the launch address is our game page with everything the SDK needs, and no secret", async () => {
  const a = await buildLaunch(deps, check, "hi");
  const u = new URL(a.url);
  assert.equal(u.origin + u.pathname, "https://sabalive.in/sud/play");
  assert.equal(u.searchParams.get("appId"), deps.appId);
  assert.equal(u.searchParams.get("appKey"), "client-key");
  assert.equal(u.searchParams.get("gameId"), check.mg_id);
  assert.equal(u.searchParams.get("roomId"), "live-123");
  assert.equal(u.searchParams.get("userId"), check.uid);
  assert.equal(u.searchParams.get("lang"), "en-US");
  assert.equal(u.searchParams.get("api"), "https://abc.supabase.co/functions/v1/sud");
  assert.equal(u.searchParams.get("test"), "1");
  assert.equal(new URL((await buildLaunch({ ...deps, testEnv: false }, check, "en")).url).searchParams.get("test"), "0");
  assert.ok(!a.url.includes(deps.secret), "the app secret must never be in the address");
  assert.equal(a.aspect, 1);
  assert.equal(a.name, "Ludo");
  assert.equal(a.uses_coins, false);
  assert.equal(a.expires_at, NOW + 2 * 3600 * 1000);
});

test("the code in the address is a valid login code for that person, the t is a launch token with the game and room", async () => {
  const u = new URL((await buildLaunch(deps, check, "en")).url);
  const code = await verifyToken(deps.secret, deps.appId, "code", u.searchParams.get("code"), NOW + 1);
  assert.equal(code.ok && code.claims.uid, check.uid);
  const t = await verifyToken(deps.secret, deps.appId, "launch", u.searchParams.get("t"), NOW + 1);
  assert.equal(t.ok && t.claims.mg, check.mg_id);
  assert.equal(t.ok && t.claims.room, "live-123");
  // the code is not usable as a launch token
  assert.equal((await verifyToken(deps.secret, deps.appId, "launch", u.searchParams.get("code"), NOW + 1)).ok, false);
});

test("app languages become SUD language codes; anything unknown is English", () => {
  assert.equal(sudLanguage("ar"), "ar-SA");
  assert.equal(sudLanguage("pt_BR"), "pt-BR");
  assert.equal(sudLanguage("en"), "en-US");
  assert.equal(sudLanguage("hi"), "en-US");
  assert.equal(sudLanguage(undefined), "en-US");
});

test("refresh: a good launch token gives a fresh code for the same person", async () => {
  const t = new URL((await buildLaunch(deps, check, "en")).url).searchParams.get("t");
  const r = await refreshCode({ ...deps, now: () => NOW + 3 * 3600 * 1000, userInfo: async () => ({ ok: true }) }, t);
  assert.equal(r.ok, true);
  if (r.ok) {
    const v = await verifyToken(deps.secret, deps.appId, "code", r.code, NOW + 3 * 3600 * 1000 + 1);
    assert.equal(v.ok && v.claims.uid, check.uid);
    assert.equal(r.expire_date, NOW + 3 * 3600 * 1000 + 2 * 3600 * 1000);
  }
});

test("refresh refuses: a code in place of the launch token, an expired token, junk, a person who is gone", async () => {
  const u = new URL((await buildLaunch(deps, check, "en")).url);
  const ok = async () => ({ ok: true });
  assert.equal((await refreshCode({ ...deps, userInfo: ok }, u.searchParams.get("code"))).ok, false);
  assert.equal((await refreshCode({ ...deps, userInfo: ok }, "junk")).ok, false);
  assert.equal((await refreshCode({ ...deps, now: () => NOW + 7 * 3600 * 1000, userInfo: ok }, u.searchParams.get("t"))).ok, false);
  const gone = await refreshCode({ ...deps, userInfo: async () => ({ ok: false }) }, u.searchParams.get("t"));
  assert.deepEqual(gone, { ok: false, msg: "unknown user" });
});
