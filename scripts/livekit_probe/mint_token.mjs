// Makes a LiveKit token for the browser test page (index.html) from the key and secret in ~/sabalive-secrets/livekit-staging.env.
//   node scripts/livekit_probe/mint_token.mjs [identity] [room] [publisher|subscriber]
// Prints the server address and a token valid for 30 minutes. The secret is read from that file (outside git) and is never printed.
// A TEST tool: it signs with the same secret as the Edge Function, so it can talk to the room without signing in to the app.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { createHmac } from 'node:crypto';

const file = process.env.LIVEKIT_ENV_FILE ?? `${homedir()}/sabalive-secrets/livekit-staging.env`;
let text;
try { text = readFileSync(file, 'utf8'); } catch { console.error(`Missing ${file}. Create it (chmod 600) with LIVEKIT_URL=, LIVEKIT_API_KEY= and LIVEKIT_API_SECRET= lines.`); process.exit(2); }
const env = Object.fromEntries(text.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#') && l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim().replace(/^["']|["']$/g, '')]));
// the file may name them LIVECORE_* (the vendor's name) or LIVEKIT_*: either works
for (const k of ['URL', 'API_KEY', 'API_SECRET']) env[`LIVEKIT_${k}`] ||= env[`LIVECORE_${k}`];
for (const k of ['LIVEKIT_URL', 'LIVEKIT_API_KEY', 'LIVEKIT_API_SECRET']) if (!env[k]) { console.error(`${k} is missing in ${file}`); process.exit(2); }

const [identity = 'probe-' + Math.random().toString(36).slice(2, 6), room = 'sabalive-probe', role = 'publisher'] = process.argv.slice(2);
const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const head = b64({ alg: 'HS256', typ: 'JWT' });
const body = b64({ iss: env.LIVEKIT_API_KEY, sub: identity, nbf: now, exp: now + 1800,
  video: { room, roomJoin: true, canPublish: role === 'publisher', canSubscribe: true, canPublishData: false } });
const sig = createHmac('sha256', env.LIVEKIT_API_SECRET).update(`${head}.${body}`).digest('base64url');
console.log(`url:      ${env.LIVEKIT_URL}`);
console.log(`identity: ${identity}   room: ${room}   role: ${role}`);
console.log(`token:    ${head}.${body}.${sig}`);
