// Tulasi game platform callbacks (merchant integration). Called by the PLATFORM, never by our app, so it is deployed with
// verify_jwt off (`supabase functions deploy tulasi --no-verify-jwt`). What protects it is not a JWT: the body is RSA-encrypted
// for us, a request needs a per-launch token that matches the uid, the database refuses anything out of proportion
// (see game_apply_balance), and the games switch (app_config.feature_flags.games_enabled) turns it all off.
//
// Callback base URL to save in the Tulasi dashboard (keep the trailing slash):
//   https://<project-ref>.supabase.co/functions/v1/tulasi/
// Secrets (set by the owner, never printed or committed):
//   TULASI_MERCHANT_PRIVATE_KEY   the merchant private key from the dashboard (PEM, or its base64 body)
//   TULASI_PLATFORM_PUBLIC_KEY    the platform public key from the dashboard
import { createClient } from "@supabase/supabase-js";
import { handle, routeOf } from "./protocol.ts";
import { loadPrivateKey, loadPublicKey } from "./rsa.ts";
import { makeRehost } from "./rehost.ts";
import { decryptPath, nativeError } from "./rsa.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PRIVATE_KEY = Deno.env.get("TULASI_MERCHANT_PRIVATE_KEY") ?? "";
const PLATFORM_KEY = Deno.env.get("TULASI_PLATFORM_PUBLIC_KEY") ?? "";
const MAX_BODY = 512 * 1024;

const json = (status: number, code: number, msg: string) =>
  new Response(JSON.stringify({ code, msg, data: "" }), { status, headers: { "Content-Type": "application/json" } });

let keys: { privateKey: any; platformPublicKey: any } | null = null;
function getKeys() {
  if (!keys) keys = { privateKey: loadPrivateKey(PRIVATE_KEY), platformPublicKey: loadPublicKey(PLATFORM_KEY) };
  return keys;
}

const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const rpc = async (fn: string, args: Record<string, unknown>) => {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
};
const rehost = makeRehost({
  fetchFn: (url, init) => fetch(url, init),
  upload: async (path, bytes, contentType) => {
    const { error } = await sb.storage.from("gift-assets").upload(path, bytes, { contentType, upsert: true });
    if (error) return null;
    return sb.storage.from("gift-assets").getPublicUrl(path).data.publicUrl;
  },
});

// Pictures are copied after the answer has been sent: the platform gives up on a slow reply.
const background = (work: Promise<unknown>) => {
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(work.catch(() => {}));
  else work.catch(() => {});
};
const setImage = async (id: number, kind: "image" | "banner", from: string, to: string) => {
  const col = kind === "image" ? "image_url" : "banner_url";
  const { error } = await sb.from("merchant_games").update({ [col]: to, updated_at: new Date().toISOString() }).eq("id", id).eq(col, from);
  if (error) throw new Error(`merchant_games: ${error.message}`);
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, 0, "method not allowed");
  if (!PRIVATE_KEY || !PLATFORM_KEY) return json(500, 0, "not configured");
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY) return json(413, 0, "too large");
  const body = await req.text();
  if (body.length > MAX_BODY) return json(413, 0, "too large");

  let k;
  try {
    k = getKeys();
  } catch (e) {
    console.error(`tulasi: ${(e as Error).message}`);
    return json(500, 0, "not configured");
  }
  const reply = await handle(routeOf(new URL(req.url).pathname), body, {
    privateKey: k.privateKey,
    platformPublicKey: k.platformPublicKey,
    rpc,
    rehost,
    setImage,
    background,
    imageBase: Deno.env.get("TULASI_IMAGE_BASE") ?? "https://game-1305970982.cos.ap-singapore.myqcloud.com",
    log: (m) => console.log(`tulasi: ${m}`),
  });
  // x-decrypt: which RSA implementation read the request (native = the runtime's, forge = the slow pure-JS fallback)
  return new Response(JSON.stringify(reply.body), { status: reply.status, headers: { "Content-Type": "application/json", "x-decrypt": decryptPath, "x-native-error": nativeError.replace(/[^\x20-\x7e]/g, " ") } });
});
