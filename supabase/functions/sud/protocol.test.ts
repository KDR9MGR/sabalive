import test from "node:test";
import assert from "node:assert/strict";
import { handleCallback, MONEY_ROUTES, ROUTES, routeOf } from "./protocol.ts";
import { mintToken, SS_TTL_MS } from "./auth.ts";
import type { Signed } from "./signature.ts";

const SECRET = "s3cret-not-real";
const APP = "1000000000000000001";
const NOW = 1_800_000_000_000;
const UID = "b1000000-0000-0000-0000-0000000000b2";
const unsigned: Signed = { present: false, valid: false, reason: "no signature" };
const good: Signed = { present: true, valid: true };
const forged: Signed = { present: true, valid: false, reason: "bad signature" };

function fake(extra: Partial<Record<string, (a: any) => any>> = {}) {
  const calls: Array<{ fn: string; args: any }> = [];
  const rpc = async (fn: string, args: any) => {
    calls.push({ fn, args });
    if (extra[fn]) return extra[fn]!(args);
    if (fn === "sud_user_info") return args.p_uid === UID ? { ok: true, uid: UID, nick_name: "Asha", avatar_url: "https://img/a.png", gender: "female", coin: 1234 } : { ok: false };
    if (fn === "sud_log_event") return null;
    if (fn === "sud_apply_score") return { ok: true, code: 0, coin: 1100 };
    throw new Error("unexpected " + fn);
  };
  return { calls, deps: { secret: SECRET, appId: APP, rpc, now: () => NOW } };
}
const tok = (kind: "code" | "ss", uid = UID, ttl = 3600_000, at = NOW) => mintToken({ secret: SECRET, appId: APP, kind, uid, ttlMs: ttl, nowMs: at }).then((m) => m.token);
const call = (route: string, body: unknown, signed: Signed, f = fake()) => handleCallback(route, JSON.stringify(body), signed, f.deps).then((r) => ({ r, f }));

test("routes are the last path segment, with or without a trailing slash", () => {
  assert.equal(routeOf("/functions/v1/sud/get_sstoken"), "get_sstoken");
  assert.equal(routeOf("/functions/v1/sud/get_sstoken/"), "get_sstoken");
  assert.equal(routeOf("/sud"), "sud");
  assert.equal(routeOf(""), "");
  for (const r of ["get_account", "get_score", "update_score"]) assert.ok(MONEY_ROUTES.has(r));
  assert.ok(!MONEY_ROUTES.has("get_sstoken"));
  assert.equal(ROUTES.length, 8);
});

test("an unknown route is 404", async () => {
  const { r } = await call("launch_everything", {}, unsigned);
  assert.equal(r.status, 404);
});

test("get_sstoken: a valid code gives an ss_token valid for 2 hours, with the user's name, avatar and gender", async () => {
  const { r } = await call("get_sstoken", { code: await tok("code") }, unsigned);
  assert.equal(r.status, 200);
  const b: any = r.body;
  assert.equal(b.ret_code, 0);
  assert.equal(b.data.expire_date, NOW + SS_TTL_MS);
  assert.deepEqual(b.data.user_info, { uid: UID, nick_name: "Asha", avatar_url: "https://img/a.png", gender: "female", is_ai: 0, ai_level: 0 });
  // the ss_token it gave works on get_user_info
  const { r: r2 } = await call("get_user_info", { ss_token: b.data.ss_token }, unsigned);
  assert.equal((r2.body as any).ret_code, 0);
  assert.equal((r2.body as any).data.nick_name, "Asha");
});

test("get_sstoken: an expired, forged or wrong-kind code is refused with SUD's sdk error numbers", async () => {
  const expired = await tok("code", UID, 1000, NOW - 10_000);
  const a: any = (await call("get_sstoken", { code: expired }, unsigned)).r.body;
  assert.equal(a.ret_code, 1);
  assert.equal(a.sdk_error_code, 1005);
  const b: any = (await call("get_sstoken", { code: "not.a.token" }, unsigned)).r.body;
  assert.equal(b.ret_code, 1);
  assert.ok([1002, 1003].includes(b.sdk_error_code));
  const c: any = (await call("get_sstoken", { code: await tok("ss") }, unsigned)).r.body;
  assert.equal(c.sdk_error_code, 1004);
  const d: any = (await call("get_sstoken", {}, unsigned)).r.body;
  assert.equal(d.ret_code, 1);
});

test("get_sstoken: a person who no longer exists (or is a ghost) gets no token", async () => {
  const gone = await tok("code", "11111111-1111-1111-1111-111111111111");
  const b: any = (await call("get_sstoken", { code: gone }, unsigned)).r.body;
  assert.equal(b.ret_code, 1);
  assert.equal(b.data.ss_token, undefined);
});

test("update_sstoken renews a valid token and refuses an expired one", async () => {
  const b: any = (await call("update_sstoken", { ss_token: await tok("ss") }, unsigned)).r.body;
  assert.equal(b.ret_code, 0);
  assert.equal(b.data.expire_date, NOW + SS_TTL_MS);
  const e: any = (await call("update_sstoken", { ss_token: await tok("ss", UID, 1000, NOW - 5000) }, unsigned)).r.body;
  assert.equal(e.ret_code, 1);
  assert.equal(e.sdk_error_code, 1005);
});

test("report_game_info is logged against the leader and never fails the call when the log fails", async () => {
  const f = fake();
  const body = { report_type: "game_settle", uid: UID, ss_token: await tok("ss"), report_msg: { mg_id_str: "146", room_id: "live-1", game_round_id: "r1", players: [] } };
  const { r } = await call("report_game_info", body, unsigned, f);
  assert.equal((r.body as any).ret_code, 0);
  const log = f.calls.find((c) => c.fn === "sud_log_event")!;
  assert.equal(log.args.p_kind, "game_settle");
  assert.equal(log.args.p_uid, UID);
  assert.equal(log.args.p_mg_id, "146");
  assert.equal(log.args.p_room_id, "live-1");
  assert.equal(log.args.p_round_id, "r1");
  const broken = fake({ sud_log_event: () => { throw new Error("db busy"); } });
  assert.equal(((await call("report_game_info", body, unsigned, broken)).r.body as any).ret_code, 0);
});

test("report_game_info: another person's uid, or no token, is refused", async () => {
  const mismatch: any = (await call("report_game_info", { report_type: "game_start", uid: "someone-else", ss_token: await tok("ss"), report_msg: {} }, unsigned)).r.body;
  assert.equal(mismatch.ret_code, 1);
  const none: any = (await call("report_game_info", { report_type: "game_start", uid: UID, report_msg: {} }, unsigned)).r.body;
  assert.equal(none.ret_code, 1);
});

test("notify is answered exactly as the docs ask and logged", async () => {
  const f = fake();
  const { r } = await call("notify", { notify_id: "n1", notify_time: "1", app_id: APP, notify_event: "sud.mg.merchant.room.users.changed", data: { room_id: "9009", mg_id: "146", player_total: 2 } }, unsigned, f);
  assert.deepEqual(r.body, { ret_code: 0, ret_msg: "SUCCESS" });
  assert.equal(f.calls.find((c) => c.fn === "sud_log_event")!.args.p_kind, "sud.mg.merchant.room.users.changed");
  const wrong: any = (await call("notify", { app_id: "another", notify_event: "x", data: {} }, unsigned)).r.body;
  assert.equal(wrong.ret_code, 1);
});

test("a request whose signature header is present but wrong is 401, on any route", async () => {
  for (const route of ["get_sstoken", "notify", "update_score"]) {
    const { r } = await call(route, { code: await tok("code") }, forged);
    assert.equal(r.status, 401, route);
  }
});

test("the money routes need a VALID signature: unsigned is 401 and nothing is touched", async () => {
  for (const route of ["get_account", "get_score", "update_score"]) {
    const f = fake();
    const { r } = await call(route, { uid: UID, order_id: "o", mg_id: "1", round_id: "r", score: 1, type: 1 }, unsigned, f);
    assert.equal(r.status, 401, route);
    assert.equal(f.calls.length, 0, route);
  }
});

test("get_account and get_score answer with the wallet when signed", async () => {
  const a: any = (await call("get_account", { uid: UID }, good)).r.body;
  assert.deepEqual(a.data, { nickname: "Asha", avatar_url: "https://img/a.png", score: 1234, vip_level: 0 });
  const s: any = (await call("get_score", { uid: UID }, good)).r.body;
  assert.deepEqual(s.data, { score: 1234 });
  assert.equal(((await call("get_score", { uid: "nobody" }, good)).r.body as any).ret_code, 1);
});

test("update_score passes the order to the database and maps its answer", async () => {
  const f = fake();
  const body = { order_id: "ord-1", mg_id: "1557194487352053761", round_id: "r1", uid: UID, score: 100, type: 1 };
  const b: any = (await call("update_score", body, good, f)).r.body;
  assert.equal(b.ret_code, 0);
  assert.deepEqual(b.data, { score: 1100 });
  assert.deepEqual(f.calls[0], { fn: "sud_apply_score", args: { p_uid: UID, p_order_id: "ord-1", p_mg_id: "1557194487352053761", p_round_id: "r1", p_score: 100, p_type: 1 } });
});

test("update_score: insufficient balance is 9000, a repeated order is 9001, other refusals are 1", async () => {
  const body = { order_id: "o", mg_id: "1", round_id: "r", uid: UID, score: 5, type: 1 };
  const nine = (code: number, msg: string) => fake({ sud_apply_score: () => ({ ok: false, code, msg, coin: 7 }) });
  const a: any = (await call("update_score", body, good, nine(9000, "insufficient balance"))).r.body;
  assert.equal(a.ret_code, 9000);
  assert.deepEqual(a.data, { score: 7 });
  const b: any = (await call("update_score", body, good, nine(9001, "duplicate order id"))).r.body;
  assert.equal(b.ret_code, 9001);
  const c: any = (await call("update_score", body, good, nine(1, "bet above the limit"))).r.body;
  assert.equal(c.ret_code, 1);
  assert.equal(c.ret_msg, "bet above the limit");
});

test("update_score: bad input never reaches the database", async () => {
  for (const bad of [{ score: -1, type: 1 }, { score: 1.5, type: 1 }, { score: "x", type: 1 }, { score: 5, type: 3 }, { score: 5 }]) {
    const f = fake();
    const b: any = (await call("update_score", { order_id: "o", mg_id: "1", round_id: "r", uid: UID, ...bad }, good, f)).r.body;
    assert.equal(b.ret_code, 1, JSON.stringify(bad));
    assert.equal(f.calls.length, 0);
  }
});

test("a body that is not JSON, or not an object, is a clean refusal; a database error is a 500 that leaks nothing", async () => {
  const f = fake();
  const a: any = (await handleCallback("get_sstoken", "not json", unsigned, f.deps)).body;
  assert.equal(a.ret_code, 1);
  const b: any = (await handleCallback("get_sstoken", "[1,2]", unsigned, f.deps)).body;
  assert.equal(b.ret_code, 1);
  const boom = fake({ sud_user_info: () => { throw new Error("password=hunter2 connection refused"); } });
  const r = await handleCallback("get_sstoken", JSON.stringify({ code: await tok("code") }), unsigned, boom.deps);
  assert.equal(r.status, 500);
  assert.ok(!JSON.stringify(r.body).includes("hunter2"));
});
