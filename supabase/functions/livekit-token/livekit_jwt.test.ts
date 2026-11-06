import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { signLiveKitToken } from "./livekit_jwt.ts";
import { buildGrant } from "./grants.ts";

const dec = (s: string) => JSON.parse(Buffer.from(s, "base64url").toString("utf8"));

test("the token is a three-part HS256 JWT LiveKit can verify with the same secret", async () => {
  const grant = buildGrant({ room: "room-1", canPublish: true });
  const jwt = await signLiveKitToken({ apiKey: "APIkey", apiSecret: "s3cret", identity: "user-1", ttlSeconds: 3600, grant, now: 1_000_000 });
  const [h, p, s] = jwt.split(".");
  assert.deepEqual(dec(h), { alg: "HS256", typ: "JWT" });
  const expected = createHmac("sha256", "s3cret").update(`${h}.${p}`).digest("base64url");
  assert.equal(s, expected, "the signature matches an independent HMAC");
  assert.notEqual(s, createHmac("sha256", "other").update(`${h}.${p}`).digest("base64url"), "and not another secret's");
});

test("claims: issuer is the key, subject the identity, valid for exactly the ttl, the room grant inside", async () => {
  const grant = buildGrant({ room: "abc", canPublish: false });
  const jwt = await signLiveKitToken({ apiKey: "K", apiSecret: "S", identity: "u9", ttlSeconds: 600, grant, now: 5000 });
  const p = dec(jwt.split(".")[1]);
  assert.equal(p.iss, "K");
  assert.equal(p.sub, "u9");
  assert.equal(p.nbf, 5000);
  assert.equal(p.exp, 5600);
  assert.deepEqual(p.video, { room: "abc", roomJoin: true, canPublish: false, canSubscribe: true, canPublishData: false });
});

test("the secret never appears in the token", async () => {
  const jwt = await signLiveKitToken({ apiKey: "K", apiSecret: "TOP-SECRET-VALUE", identity: "u", ttlSeconds: 60, grant: buildGrant({ room: "r", canPublish: true }) });
  assert.ok(!jwt.includes("TOP-SECRET-VALUE"));
  assert.ok(!Buffer.from(jwt.split(".")[1], "base64url").toString().includes("TOP-SECRET-VALUE"));
});

test("a viewer can listen only: no publishing, no data channel", () => {
  const g = buildGrant({ room: "r", canPublish: false, audioOnly: true });
  assert.equal(g.canPublish, false);
  assert.equal(g.canSubscribe, true);
  assert.equal(g.canPublishData, false);
  assert.equal(g.canPublishSources, undefined, "nothing to restrict when nothing can be published");
});

test("a speaker in an audio room may send the microphone only", () => {
  const g = buildGrant({ room: "r", canPublish: true, audioOnly: true });
  assert.equal(g.canPublish, true);
  // a NUMBER (TrackSource.MICROPHONE = 2): the LiveCore server rejects the text spelling with a 500 (checked against its /rtc/validate)
  assert.deepEqual(g.canPublishSources, [2]);
  assert.equal(g.canPublishData, false);
});

test("a publisher in another kind of room is not limited to the microphone (video lives and PK send a camera)", () => {
  const g = buildGrant({ room: "r", canPublish: true, audioOnly: false });
  assert.equal(g.canPublish, true);
  assert.equal(g.canPublishSources, undefined);
});

test("a ghost watcher is hidden and can never publish, even if asked to", () => {
  const g = buildGrant({ room: "r", canPublish: true, hidden: true, audioOnly: true });
  assert.equal(g.hidden, true);
  assert.equal(g.canPublish, false);
  assert.equal(g.canSubscribe, true);
  assert.equal(g.canPublishSources, undefined);
});

test("an ordinary participant is not marked hidden", () => {
  assert.equal(buildGrant({ room: "r", canPublish: false }).hidden, undefined);
});
