// A LiveKit access token, signed by hand (HS256) instead of with the vendor's server SDK: the format is a plain, stable JWT, this keeps the function
// free of a package that has to be kept in step with the server, and Node's test runner can check it (scripts/test_functions.sh).
// The API secret only ever lives in the function's environment (LIVEKIT_API_SECRET) and never leaves this file's caller.

/** What LiveKit lets a holder do in a room (the `video` claim). Names are LiveKit's own. */
export type VideoGrant = {
  room: string;
  roomJoin: true;
  canPublish: boolean;
  canSubscribe: boolean;
  canPublishData: boolean;
  /** Which tracks a publisher may send, as LiveKit's TrackSource NUMBERS (camera 1, microphone 2). Omitted = any. The LiveCore server rejects the text spelling
   *  ("microphone": 500 "Cannot convert TrackSource microphone to string"; checked against its /rtc/validate on 2026-11-06) and accepts the number, so numbers it is. */
  canPublishSources?: number[];
  /** A hidden participant is not listed to the others: how a ghost watches without being seen. */
  hidden?: boolean;
};

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const enc = new TextEncoder();

export async function signLiveKitToken(opts: {
  apiKey: string;
  apiSecret: string;
  identity: string;
  ttlSeconds: number;
  grant: VideoGrant;
  /** Seconds since the epoch; only tests pass it. */
  now?: number;
}): Promise<string> {
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  const header = { alg: "HS256", typ: "JWT" };
  const payload = {
    iss: opts.apiKey,
    sub: opts.identity,
    nbf: now,
    exp: now + opts.ttlSeconds,
    video: opts.grant,
  };
  const head = b64url(enc.encode(JSON.stringify(header)));
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const key = await crypto.subtle.importKey("raw", enc.encode(opts.apiSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${head}.${body}`)));
  return `${head}.${body}.${b64url(sig)}`;
}
