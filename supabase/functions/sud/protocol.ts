// What SUD's game servers ask of us (docs.sud.tech > Server > HTTPS service callback). Pure: the database and the clock come in through `Deps`, so the whole
// protocol is unit-tested without Deno or a network. Every answer is HTTP 200 with { ret_code, ret_msg, sdk_error_code, data } (ret_code 0 = success);
// only a request that fails the signature check gets HTTP 401.
import { mintToken, sdkErrorCode, SS_TTL_MS, verifyToken } from "./auth.ts";
import type { Signed } from "./signature.ts";

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<any>;
export interface Deps {
  secret: string;
  appId: string;
  rpc: Rpc;
  now: () => number;
  log?: (m: string) => void;
}
export interface Reply {
  status: number;
  body: unknown;
}

export const ROUTES = ["get_sstoken", "update_sstoken", "get_user_info", "report_game_info", "notify", "get_account", "get_score", "update_score"] as const;
/** These move or reveal coins: a valid Sud-Signature is mandatory. The others are protected by the tokens themselves (ours, short-lived) and the signature is checked when it is sent. */
export const MONEY_ROUTES: ReadonlySet<string> = new Set(["get_account", "get_score", "update_score"]);

export const routeOf = (pathname: string): string => pathname.split("/").filter(Boolean).pop() ?? "";

const ok = (data: unknown = {}): Reply => ({ status: 200, body: { ret_code: 0, ret_msg: "success", sdk_error_code: 0, data } });
const fail = (msg: string, sdk = 0, retCode = 1, data: unknown = {}): Reply => ({ status: 200, body: { ret_code: retCode, ret_msg: msg, sdk_error_code: sdk, data } });
const unauthorized = (why: string): Reply => ({ status: 401, body: { ret_code: 1, ret_msg: `signature: ${why}`, sdk_error_code: 0, data: {} } });

const isObject = (v: unknown): v is Record<string, any> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown, max = 200): string => (typeof v === "string" ? v : typeof v === "number" ? String(v) : "").slice(0, max);

const userInfoObject = (u: Record<string, any>) => ({ uid: String(u.uid), nick_name: String(u.nick_name), avatar_url: String(u.avatar_url ?? ""), gender: String(u.gender ?? ""), is_ai: 0, ai_level: 0 });

export async function handleCallback(route: string, rawBody: string, signed: Signed, deps: Deps): Promise<Reply> {
  if (!(ROUTES as readonly string[]).includes(route)) return { status: 404, body: { ret_code: 1, ret_msg: "unknown route", data: {} } };
  if (signed.present && !signed.valid) return unauthorized(signed.reason ?? "invalid");
  if (MONEY_ROUTES.has(route) && !signed.valid) return unauthorized(signed.reason ?? "required");

  let body: Record<string, any>;
  try {
    const parsed = JSON.parse(rawBody);
    if (!isObject(parsed)) return fail("the body must be a JSON object");
    body = parsed;
  } catch {
    return fail("the body is not JSON");
  }

  try {
    switch (route) {
      case "get_sstoken": return await getSSToken(body, deps);
      case "update_sstoken": return await updateSSToken(body, deps);
      case "get_user_info": return await getUserInfo(body, deps);
      case "report_game_info": return await reportGameInfo(body, deps);
      case "notify": return await notify(body, deps);
      case "get_account": return await getAccount(body, deps);
      case "get_score": return await getScore(body, deps);
      case "update_score": return await updateScore(body, deps);
    }
  } catch (e) {
    deps.log?.(`${route}: ${(e as Error).message}`);
    return { status: 500, body: { ret_code: 1, ret_msg: "server error", sdk_error_code: 0, data: {} } };
  }
  return fail("unknown route");
}

async function getSSToken(body: Record<string, any>, d: Deps): Promise<Reply> {
  const v = await verifyToken(d.secret, d.appId, "code", body.code, d.now());
  if (!v.ok) return fail(`code ${v.error}`, sdkErrorCode(v.error));
  const info = await d.rpc("sud_user_info", { p_uid: v.claims.uid });
  if (!info?.ok) return fail("unknown user", sdkErrorCode("invalid"));
  const ss = await mintToken({ secret: d.secret, appId: d.appId, kind: "ss", uid: v.claims.uid, ttlMs: SS_TTL_MS, nowMs: d.now() });
  return ok({ ss_token: ss.token, expire_date: ss.expireDate, user_info: userInfoObject(info) });
}

async function updateSSToken(body: Record<string, any>, d: Deps): Promise<Reply> {
  const v = await verifyToken(d.secret, d.appId, "ss", body.ss_token, d.now());
  if (!v.ok) return fail(`ss_token ${v.error}`, sdkErrorCode(v.error));
  const info = await d.rpc("sud_user_info", { p_uid: v.claims.uid });
  if (!info?.ok) return fail("unknown user", sdkErrorCode("invalid"));
  const ss = await mintToken({ secret: d.secret, appId: d.appId, kind: "ss", uid: v.claims.uid, ttlMs: SS_TTL_MS, nowMs: d.now() });
  return ok({ ss_token: ss.token, expire_date: ss.expireDate });
}

async function getUserInfo(body: Record<string, any>, d: Deps): Promise<Reply> {
  const v = await verifyToken(d.secret, d.appId, "ss", body.ss_token, d.now());
  if (!v.ok) return fail(`ss_token ${v.error}`, sdkErrorCode(v.error));
  const info = await d.rpc("sud_user_info", { p_uid: v.claims.uid });
  if (!info?.ok) return fail("unknown user", sdkErrorCode("invalid"));
  return ok(userInfoObject(info));
}

// Game start / settle reports. The leader's ss_token proves who reported; what is reported is only logged (a short log, kept 14 days).
async function reportGameInfo(body: Record<string, any>, d: Deps): Promise<Reply> {
  const v = await verifyToken(d.secret, d.appId, "ss", body.ss_token, d.now());
  if (!v.ok) return fail(`ss_token ${v.error}`, sdkErrorCode(v.error));
  if (str(body.uid) !== v.claims.uid) return fail("uid does not match the token", sdkErrorCode("invalid"));
  const msg = isObject(body.report_msg) ? body.report_msg : {};
  await logEvent(d, str(body.report_type, 60) || "report", v.claims.uid, msg, msg);
  return ok({});
}

// Asynchronous notifications (only the events SUD has enabled for us). Answered { ret_code: 0, ret_msg: "SUCCESS" } as the docs ask.
async function notify(body: Record<string, any>, d: Deps): Promise<Reply> {
  if (body.app_id !== undefined && str(body.app_id) !== d.appId) return { status: 200, body: { ret_code: 1, ret_msg: "wrong app" } };
  const data = isObject(body.data) ? body.data : {};
  await logEvent(d, str(body.notify_event, 80) || "notify", "", data, body);
  return { status: 200, body: { ret_code: 0, ret_msg: "SUCCESS" } };
}

async function logEvent(d: Deps, kind: string, uid: string, fields: Record<string, any>, payload: unknown) {
  try {
    await d.rpc("sud_log_event", {
      p_kind: kind,
      p_uid: uid || null,
      p_mg_id: str(fields.mg_id_str ?? fields.mg_id, 40) || null,
      p_room_id: str(fields.room_id, 80) || null,
      p_round_id: str(fields.game_round_id ?? fields.round_id, 120) || null,
      p_payload: payload,
    });
  } catch (e) {
    d.log?.(`log ${kind}: ${(e as Error).message}`); // a failed log must never fail SUD's call
  }
}

async function getAccount(body: Record<string, any>, d: Deps): Promise<Reply> {
  const info = await d.rpc("sud_user_info", { p_uid: str(body.uid) });
  if (!info?.ok) return fail("unknown user");
  return ok({ nickname: String(info.nick_name), avatar_url: String(info.avatar_url ?? ""), score: Number(info.coin), vip_level: 0 });
}

async function getScore(body: Record<string, any>, d: Deps): Promise<Reply> {
  const info = await d.rpc("sud_user_info", { p_uid: str(body.uid) });
  if (!info?.ok) return fail("unknown user");
  return ok({ score: Number(info.coin) });
}

// A consume (type 1) or a gain (type 2) of coins. Exactly once per order_id; the limits are the database's (sud_apply_score).
// SUD's special codes: 9000 insufficient balance, 9001 duplicate order id.
async function updateScore(body: Record<string, any>, d: Deps): Promise<Reply> {
  const score = typeof body.score === "number" ? body.score : Number(body.score);
  const type = typeof body.type === "number" ? body.type : Number(body.type);
  if (!Number.isFinite(score) || !Number.isInteger(score) || score < 0) return fail("invalid score");
  if (type !== 1 && type !== 2) return fail("invalid type");
  const r = await d.rpc("sud_apply_score", {
    p_uid: str(body.uid), p_order_id: str(body.order_id, 130), p_mg_id: str(body.mg_id, 40), p_round_id: str(body.round_id, 200), p_score: score, p_type: type,
  });
  const code = Number(r?.code ?? 1);
  if (r?.ok) return ok({ score: Number(r.coin) });
  return fail(String(r?.msg ?? "failure"), 0, code === 9000 || code === 9001 ? code : 1, r?.coin !== undefined ? { score: Number(r.coin) } : {});
}
