// SUD signs every callback it sends us (docs: "callback signature verify"): the headers Sud-AppId, Sud-Timestamp, Sud-Nonce and Sud-Signature, where the
// signature is the lower-case HEX of HMAC-SHA1(app secret, "<appId>\n<timestamp>\n<nonce>\n<raw request body>\n").
import { hmacHex, safeEqual } from "./auth.ts";

export const signatureString = (appId: string, timestamp: string, nonce: string, body: string): string => `${appId}\n${timestamp}\n${nonce}\n${body}\n`;

export const sudSignature = (secret: string, appId: string, timestamp: string, nonce: string, body: string): Promise<string> =>
  hmacHex("SHA-1", secret, signatureString(appId, timestamp, nonce, body));

export interface Signed {
  /** the request carried a Sud-Signature header at all */
  present: boolean;
  /** it was there AND checked out (right app, right signature, a believable time) */
  valid: boolean;
  reason?: string;
}

type HeaderBag = { get(name: string): string | null };

/** How far a callback's timestamp may be from our clock. SUD's examples mix seconds and milliseconds, and clocks differ: the window is generous, the HMAC is the proof. */
export const TIMESTAMP_TOLERANCE_MS = 60 * 60 * 1000;

export async function verifySudRequest(opts: { secret: string; appId: string; headers: HeaderBag; body: string; nowMs: number }): Promise<Signed> {
  const signature = opts.headers.get("sud-signature");
  if (!signature) return { present: false, valid: false, reason: "no signature" };
  const appId = opts.headers.get("sud-appid") ?? "";
  const timestamp = opts.headers.get("sud-timestamp") ?? "";
  const nonce = opts.headers.get("sud-nonce") ?? "";
  if (appId !== opts.appId) return { present: true, valid: false, reason: "wrong app" };
  if (/^\d{9,14}$/.test(timestamp)) {
    const ms = timestamp.length >= 12 ? Number(timestamp) : Number(timestamp) * 1000;
    if (Math.abs(opts.nowMs - ms) > TIMESTAMP_TOLERANCE_MS) return { present: true, valid: false, reason: "stale timestamp" };
  }
  const expected = await sudSignature(opts.secret, appId, timestamp, nonce, opts.body);
  return safeEqual(expected, signature.toLowerCase()) ? { present: true, valid: true } : { present: true, valid: false, reason: "bad signature" };
}
