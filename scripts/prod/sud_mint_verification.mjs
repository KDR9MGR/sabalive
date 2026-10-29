// Makes the four TEST BODIES SUD's console "Verification" button sends to our callbacks, with VALID tokens (the console refuses to save a callback address until our function
// answers a real-looking request with ret_code 0). Called by scripts/prod/sud_verification_bodies.sh; reads  {appId, secret, uid}  as JSON on STDIN (so the secret is never on a
// command line or in the environment) and prints the four bodies as JSON. The tokens are the same login tokens the app hands to SUD's SDK, signed with the app secret: they log in as
// that one person for 2 hours and can do nothing else (coin movements need SUD's own signature). The secret itself is never printed.
import { mintToken, CODE_TTL_MS, SS_TTL_MS } from "../../supabase/functions/sud/auth.ts";

const input = JSON.parse(await new Response(process.stdin).text());
const { appId, secret, uid } = input;
if (!/^[0-9]{10,25}$/.test(appId ?? "") || !secret || !/^[0-9a-f-]{36}$/i.test(uid ?? "")) {
  console.error("bad input");
  process.exit(2);
}
const now = Date.now();
const code = await mintToken({ secret, appId, kind: "code", uid, ttlMs: CODE_TTL_MS, nowMs: now });
const ss = await mintToken({ secret, appId, kind: "ss", uid, ttlMs: SS_TTL_MS, nowMs: now });
process.stdout.write(JSON.stringify({
  get_sstoken: { code: code.token },
  update_sstoken: { ss_token: ss.token },
  report_game_info: { ss_token: ss.token, uid, report_type: "game_start", report_msg: { mg_id: "1468180338417074177", room_id: "verification", game_round_id: "verification" } },
  notify: {},
  expires_at: new Date(Math.min(code.expireDate, ss.expireDate)).toISOString(),
}));
