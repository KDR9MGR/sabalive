// The three tokens of the SUD integration, all HS256 JWTs signed with the app secret (SudMGPAuth does the same, so SUD's own tools can read them):
//   code     "short-term token": the app's login for ONE game launch. The page hands it to the SUD SDK, SUD's game server presents it to our get_sstoken.
//   ss       "SSToken": what SUD's game server uses afterwards (update_sstoken, get_user_info, report_game_info).
//   launch   ours: lets the game page ask for a fresh code when the SDK says the code expired, without a user login.
// The claims are { uid, exp (seconds), app_id, k } with k = 'code' | 'ss' | 'launch': a token of one kind is refused where another is needed.
// Pure Web Crypto: it runs in Deno (the Edge Function) and in Node (the unit tests).

const enc = new TextEncoder();
const dec = new TextDecoder();

const b64url = (bytes: Uint8Array): string => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const fromB64url = (s: string): Uint8Array => {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};
const toHex = (bytes: Uint8Array): string => [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");

export async function hmac(algo: "SHA-256" | "SHA-1", secret: string, data: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: algo }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(data)));
}
export const hmacHex = async (algo: "SHA-256" | "SHA-1", secret: string, data: string): Promise<string> => toHex(await hmac(algo, secret, data));

/** Compares two strings without stopping at the first difference. */
export function safeEqual(a: string, b: string): boolean {
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export type Kind = "code" | "ss" | "launch";
export interface Claims {
  uid: string;
  exp: number;
  app_id: string;
  k: Kind;
  [extra: string]: unknown;
}

export async function signToken(secret: string, claims: Claims): Promise<string> {
  const head = b64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = b64url(enc.encode(JSON.stringify(claims)));
  const sig = b64url(await hmac("SHA-256", secret, `${head}.${body}`));
  return `${head}.${body}.${sig}`;
}

export type Verified = { ok: true; claims: Claims } | { ok: false; error: "decode" | "verify" | "invalid" | "expired" };

/** SUD's own error numbers for a token problem (SudMGPAuth): 1002 signature, 1003 unreadable, 1004 wrong claims, 1005 expired. */
export const sdkErrorCode = (e: "decode" | "verify" | "invalid" | "expired"): number => ({ verify: 1002, decode: 1003, invalid: 1004, expired: 1005 })[e];

export async function verifyToken(secret: string, appId: string, kind: Kind, token: unknown, nowMs: number): Promise<Verified> {
  if (typeof token !== "string" || token.length > 4000) return { ok: false, error: "decode" };
  const parts = token.split(".");
  if (parts.length !== 3) return { ok: false, error: "decode" };
  let claims: Claims;
  try {
    const head = JSON.parse(dec.decode(fromB64url(parts[0])));
    claims = JSON.parse(dec.decode(fromB64url(parts[1])));
    if (head?.alg !== "HS256") return { ok: false, error: "verify" };
  } catch {
    return { ok: false, error: "decode" };
  }
  const expected = b64url(await hmac("SHA-256", secret, `${parts[0]}.${parts[1]}`));
  if (!safeEqual(expected, parts[2])) return { ok: false, error: "verify" };
  if (typeof claims?.uid !== "string" || claims.uid === "" || claims.app_id !== appId || claims.k !== kind || typeof claims.exp !== "number") {
    return { ok: false, error: "invalid" };
  }
  if (claims.exp * 1000 <= nowMs) return { ok: false, error: "expired" };
  return { ok: true, claims };
}

export interface Minted {
  token: string;
  /** milliseconds since the epoch, as SUD's `expire_date` wants it */
  expireDate: number;
}

export async function mintToken(opts: { secret: string; appId: string; kind: Kind; uid: string; ttlMs: number; nowMs: number; extra?: Record<string, unknown> }): Promise<Minted> {
  const expireDate = opts.nowMs + opts.ttlMs;
  const token = await signToken(opts.secret, { ...(opts.extra ?? {}), uid: opts.uid, exp: Math.floor(expireDate / 1000), app_id: opts.appId, k: opts.kind });
  return { token, expireDate };
}

/** SUD treats anything under half an hour as half an hour, and 2 hours is its default. */
export const CODE_TTL_MS = 2 * 60 * 60 * 1000;
export const SS_TTL_MS = 2 * 60 * 60 * 1000;
export const LAUNCH_TTL_MS = 6 * 60 * 60 * 1000;
