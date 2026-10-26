// Opening a game from the app, and renewing a login code for the game page.
//
// The app (signed in) asks `launch`; the database decides whether this person may open this game (sud_launch_check); we mint the one-time login CODE and
// answer with the address of OUR game page (the web SDK of SUD runs in it) carrying everything it needs in the query string, including a longer-lived LAUNCH
// token the page can swap for a fresh code when the SDK reports that the code expired. Nothing secret is in the address: the app secret never leaves the server
// (the app key is the SDK's public client key).
import { CODE_TTL_MS, LAUNCH_TTL_MS, mintToken, verifyToken } from "./auth.ts";

export interface LaunchCheck {
  ok: boolean;
  mg_id: string;
  uid: string;
  room_id: string;
  uses_coins: boolean;
  aspect: number | null;
  name: string;
}

/** SUD's language codes for the languages the app has; anything else is English. */
export const sudLanguage = (lang: unknown): string => {
  const l = String(lang ?? "").toLowerCase().replace("_", "-");
  const base = l.split("-")[0];
  return ({ en: "en-US", ar: "ar-SA", pt: "pt-BR", id: "id-ID", tr: "tr-TR", vi: "vi-VN", es: "es-MX" } as Record<string, string>)[base] ?? "en-US";
};

export interface LaunchDeps {
  secret: string;
  appId: string;
  appKey: string;
  pageUrl: string;
  /** where the page asks for a fresh code, e.g. https://<ref>.supabase.co/functions/v1/sud (the page adds /refresh) */
  apiBase: string;
  /** SUD has a test and a production environment (initSDK's isTestEnv); true until SUD has put the app live */
  testEnv: boolean;
  now: () => number;
}

export interface LaunchAnswer {
  url: string;
  aspect: number | null;
  uses_coins: boolean;
  name: string;
  mg_id: string;
  room_id: string;
  expires_at: number;
}

export async function buildLaunch(deps: LaunchDeps, check: LaunchCheck, lang: unknown): Promise<LaunchAnswer> {
  const now = deps.now();
  const code = await mintToken({ secret: deps.secret, appId: deps.appId, kind: "code", uid: check.uid, ttlMs: CODE_TTL_MS, nowMs: now });
  const launch = await mintToken({ secret: deps.secret, appId: deps.appId, kind: "launch", uid: check.uid, ttlMs: LAUNCH_TTL_MS, nowMs: now, extra: { mg: check.mg_id, room: check.room_id } });
  const u = new URL(deps.pageUrl);
  u.searchParams.set("appId", deps.appId);
  u.searchParams.set("appKey", deps.appKey);
  u.searchParams.set("gameId", check.mg_id);
  u.searchParams.set("roomId", check.room_id);
  u.searchParams.set("userId", check.uid);
  u.searchParams.set("code", code.token);
  u.searchParams.set("t", launch.token);
  u.searchParams.set("api", deps.apiBase);
  u.searchParams.set("test", deps.testEnv ? "1" : "0");
  u.searchParams.set("lang", sudLanguage(lang));
  return { url: u.toString(), aspect: check.aspect, uses_coins: check.uses_coins, name: check.name, mg_id: check.mg_id, room_id: check.room_id, expires_at: code.expireDate };
}

/** The game page's request for a new code. The launch token proves it came from a launch of this person; the person must still exist and not be a ghost. */
export async function refreshCode(
  deps: LaunchDeps & { userInfo: (uid: string) => Promise<{ ok?: boolean } | null> },
  launchToken: unknown,
): Promise<{ ok: true; code: string; expire_date: number } | { ok: false; msg: string }> {
  const v = await verifyToken(deps.secret, deps.appId, "launch", launchToken, deps.now());
  if (!v.ok) return { ok: false, msg: `launch token ${v.error}` };
  const info = await deps.userInfo(v.claims.uid);
  if (!info?.ok) return { ok: false, msg: "unknown user" };
  const code = await mintToken({ secret: deps.secret, appId: deps.appId, kind: "code", uid: v.claims.uid, ttlMs: CODE_TTL_MS, nowMs: deps.now() });
  return { ok: true, code: code.token, expire_date: code.expireDate };
}
