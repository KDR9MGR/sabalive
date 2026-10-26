// SUD game platform (console.sud.tech, "GI Cloud"): login for the games, and the callbacks SUD's servers make. Two kinds of caller, so this function is deployed
// with verify_jwt OFF (`supabase functions deploy sud --no-verify-jwt`) and does its own checking:
//   POST .../sud/launch            our app, signed in (the user's JWT is verified here with auth.getUser): may this person open this game? -> the game page address
//   POST .../sud/refresh           the game page: a fresh login code, proved by the launch token that `launch` gave it (CORS open: the token is the credential)
//   POST .../sud/get_sstoken, update_sstoken, get_user_info, report_game_info, notify     SUD's servers (the first four are the callback URLs to save in the console)
//   POST .../sud/get_account, get_score, update_score                                      coin games: a valid Sud-Signature is mandatory
// Callback base URL for the console (no trailing slash needed): https://<project-ref>.supabase.co/functions/v1/sud/<route>
// Secrets (set by the owner, never printed or committed; a name is matched ignoring capitals, so SUD_App_Key works as SUD_APP_KEY, see env.ts):
//   SUD_APP_ID      the application id (a long number)
//   SUD_APP_KEY     the application key (the SDK's client key: it goes to the game page)
//   SUD_APP_SECRET  the application secret: signs our tokens and verifies SUD's callbacks. It never leaves this server.
//   SUD_GAME_PAGE_URL (optional)  where the web SDK page lives; default https://sabalive.in/sud/play
//   SUD_TEST_ENV (optional)       "1" (the default) = the SDK uses SUD's test environment; "0" once SUD has put the application live
import { createClient } from "@supabase/supabase-js";
import { handleCallback, routeOf } from "./protocol.ts";
import { verifySudRequest } from "./signature.ts";
import { buildLaunch, refreshCode } from "./launch.ts";
import { envValue } from "./env.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// matched ignoring capitals: the dashboard keeps a secret's name as typed (SUD_App_Key), which Deno would treat as another variable (see env.ts)
const ENV = Deno.env.toObject();
const APP_ID = envValue(ENV, "SUD_APP_ID");
const APP_KEY = envValue(ENV, "SUD_APP_KEY");
const APP_SECRET = envValue(ENV, "SUD_APP_SECRET");
const PAGE_URL = envValue(ENV, "SUD_GAME_PAGE_URL") || "https://sabalive.in/sud/play";
// SUD has a test and a production environment. Until SUD has put the application live the SDK must use the test one: SUD_TEST_ENV=1. Set it to 0 (or delete it) at launch.
const TEST_ENV = (envValue(ENV, "SUD_TEST_ENV") || "1") !== "0";
const MAX_BODY = 256 * 1024;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...cors, ...extra } });

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const rpc = async (fn: string, args: Record<string, unknown>) => {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
};
const now = () => Date.now();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json(405, { error: "method not allowed" });
  if (!APP_ID || !APP_SECRET || !APP_KEY) {
    // only facts about which secret is empty, never any value
    return json(500, { ret_code: 1, ret_msg: "not configured", error: "not configured" }, { "x-config": `empty: id=${!APP_ID} key=${!APP_KEY} secret=${!APP_SECRET}` });
  }
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY) return json(413, { error: "too large" });
  const body = await req.text();
  if (body.length > MAX_BODY) return json(413, { error: "too large" });
  const route = routeOf(new URL(req.url).pathname);
  const launchDeps = { secret: APP_SECRET, appId: APP_ID, appKey: APP_KEY, pageUrl: PAGE_URL, apiBase: `${SUPABASE_URL}/functions/v1/sud`, testEnv: TEST_ENV, now };

  if (route === "launch") {
    const auth = req.headers.get("Authorization") ?? "";
    if (!auth.startsWith("Bearer ")) return json(401, { error: "Sign in to play" });
    const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } }, auth: { persistSession: false, autoRefreshToken: false } });
    const { data: who } = await asUser.auth.getUser();
    if (!who?.user) return json(401, { error: "Sign in to play" });
    let input: any = {};
    try { input = body ? JSON.parse(body) : {}; } catch { return json(400, { error: "bad request" }); }
    const gameId = Number(input.gameId);
    if (!Number.isInteger(gameId) || gameId <= 0) return json(400, { error: "bad request" });
    // the database decides (switches, age for coin games, hidden / off games): its messages are written for the person
    const { data: check, error } = await asUser.rpc("sud_launch_check", { p_game_id: gameId, p_room: typeof input.roomId === "string" ? input.roomId : null });
    if (error || !check?.ok) return json(400, { error: error?.message ?? "This game is not available right now" });
    return json(200, await buildLaunch(launchDeps, check, input.lang));
  }

  if (route === "refresh") {
    let input: any = {};
    try { input = body ? JSON.parse(body) : {}; } catch { return json(400, { error: "bad request" }); }
    const r = await refreshCode({ ...launchDeps, userInfo: (uid) => rpc("sud_user_info", { p_uid: uid }) }, input.t);
    return r.ok ? json(200, { code: r.code, expire_date: r.expire_date }) : json(401, { error: r.msg });
  }

  // SUD's servers
  const signed = await verifySudRequest({ secret: APP_SECRET, appId: APP_ID, headers: req.headers, body, nowMs: now() });
  const reply = await handleCallback(route, body, signed, { secret: APP_SECRET, appId: APP_ID, rpc, now, log: (m) => console.log(`sud: ${m}`) });
  return json(reply.status, reply.body);
});
