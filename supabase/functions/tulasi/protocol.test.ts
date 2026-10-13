// deno-lint-ignore-file no-explicit-any
import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { handle, routeOf, type Deps } from "./protocol.ts";
import { decryptBigData, encryptBigData, loadPrivateKey, loadPublicKey } from "./rsa.ts";

const pair = () => crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const spki = (k: crypto.KeyObject) => k.export({ type: "spki", format: "pem" }).toString();
const pkcs8 = (k: crypto.KeyObject) => k.export({ type: "pkcs8", format: "pem" }).toString();

const merchant = pair(); // our keys
const platform = pair(); // theirs
const merchantPriv = loadPrivateKey(pkcs8(merchant.privateKey));
const merchantPub = loadPublicKey(spki(merchant.publicKey));
const platformPriv = loadPrivateKey(pkcs8(platform.privateKey));
const platformPub = loadPublicKey(spki(platform.publicKey));

/** The platform's request: JSON encrypted with OUR public key. */
const request = (obj: unknown) => encryptBigData(merchantPub, JSON.stringify(obj));
/** What we answered, decrypted the way the platform would. */
const readData = (r: { body: { data: string } }) => JSON.parse(decryptBigData(platformPriv, r.body.data));

function deps(rpcImpl: (fn: string, args: any) => Promise<any>, extra: Partial<Deps> = {}): Deps & { calls: Array<[string, any]>; logs: string[] } {
  const calls: Array<[string, any]> = [];
  const logs: string[] = [];
  return {
    privateKey: merchantPriv,
    platformPublicKey: platformPub,
    rpc: async (fn, args) => {
      calls.push([fn, args]);
      return rpcImpl(fn, args);
    },
    log: (m) => logs.push(m),
    calls,
    logs,
    ...extra,
  };
}

test("routeOf takes the last path segment", () => {
  assert.equal(routeOf("/functions/v1/tulasi/userInformation"), "userInformation");
  assert.equal(routeOf("/tulasi/updateBalance/"), "updateBalance");
  assert.equal(routeOf("/"), "");
});

test("userInformation: the user's profile and balance, encrypted for the platform", async () => {
  const d = deps(async () => ({ ok: true, id: 10001, coin: 9800, gameCoin: 0, nickname: "आरव", avatar: "https://x/a.png" }));
  const r = await handle("userInformation", request({ token: "DA84Cf9A3021c666F145Bd45ACe0aFDB", gameType: "lucky99" }), d);
  assert.equal(r.status, 200);
  assert.equal(r.body.code, 1);
  assert.equal(r.body.msg, "success");
  assert.deepEqual(readData(r), { id: 10001, coin: 9800, gameCoin: 0, nickname: "आरव", avatar: "https://x/a.png" });
  assert.deepEqual(d.calls, [["game_get_user", { p_token: "DA84Cf9A3021c666F145Bd45ACe0aFDB" }]]);
});

test("userInformation: an unknown token is a refusal with no data; a missing token never reaches the database", async () => {
  const d = deps(async () => ({ ok: false, msg: "invalid token" }));
  const r = await handle("userInformation", request({ token: "nope" }), d);
  assert.deepEqual(r.body, { code: 0, msg: "invalid token", data: "" });
  const r2 = await handle("userInformation", request({ gameType: "x" }), d);
  assert.equal(r2.body.code, 0);
  assert.equal(d.calls.length, 1);
});

test("updateBalance: every field reaches the database function, the reply carries the new balance", async () => {
  const d = deps(async () => ({ ok: true, id: 10001, coin: 9700 }));
  const r = await handle("updateBalance", request({
    token: "T", gameToken: "G", transactionId: "1255759810054324225", uid: 10001, type: 0, coin: 100, gameCoin: 0, gameId: 1,
    gameType: "lucky99Blue", timestamp: 1741854044311, gameEndTimestamp: 1741854050000, gameStartTimestamp: 1741854040000, roomId: 111,
    ext: "extendData", remark: "bet",
  }), d);
  assert.equal(r.body.code, 1);
  assert.deepEqual(readData(r), { id: 10001, coin: 9700 });
  assert.deepEqual(d.calls[0], ["game_apply_balance", {
    p_token: "T", p_uid: 10001, p_transaction_id: "1255759810054324225", p_type: 0, p_coin: 100, p_game_id: "1", p_game_type: "lucky99Blue",
    p_timestamp: 1741854044311, p_game_start: 1741854040000, p_game_end: 1741854050000, p_ext: "extendData", p_remark: "bet",
  }]);
});

test("updateBalance: numbers sent as text are understood, and a transaction id stays text (no rounding of a long id)", async () => {
  const d = deps(async () => ({ ok: true, id: 7, coin: 5 }));
  await handle("updateBalance", request({ token: "T", transactionId: "9007199254740993", uid: "7", type: "1", coin: "50", timestamp: "1741854044311", gameType: "g" }), d);
  const a = d.calls[0][1];
  assert.equal(a.p_transaction_id, "9007199254740993");
  assert.equal(a.p_uid, 7);
  assert.equal(a.p_type, 1);
  assert.equal(a.p_coin, 50);
});

test("updateBalance: bad requests are refused before the database", async () => {
  const d = deps(async () => ({ ok: true }));
  const base = { token: "T", transactionId: "t1", uid: 1, type: 0, coin: 10, timestamp: 1 };
  for (const bad of [
    { ...base, token: "" }, { ...base, uid: "abc" }, { ...base, type: 0.5 }, { ...base, transactionId: "" }, { ...base, transactionId: undefined },
    { ...base, coin: -5 }, { ...base, coin: 1.5 }, { ...base, coin: undefined },
  ]) {
    const r = await handle("updateBalance", request(bad), d);
    assert.equal(r.body.code, 0, JSON.stringify(bad));
  }
  assert.equal(d.calls.length, 0);
});

test("updateBalance: the database's refusal is passed on as code 0 with its reason", async () => {
  const d = deps(async () => ({ ok: false, msg: "insufficient balance", coin: 5 }));
  const r = await handle("updateBalance", request({ token: "T", transactionId: "t1", uid: 1, type: 0, coin: 10, timestamp: 1 }), d);
  assert.deepEqual(r.body, { code: 0, msg: "insufficient balance", data: "" });
  assert.equal(r.status, 200);
});

test("a database error is a 500 that does not leak the reason, and is logged without the request", async () => {
  const d = deps(async () => {
    throw new Error("game_apply_balance: connection refused");
  });
  const r = await handle("updateBalance", request({ token: "SECRET-TOKEN", transactionId: "t1", uid: 1, type: 0, coin: 10, timestamp: 1 }), d);
  assert.equal(r.status, 500);
  assert.deepEqual(r.body, { code: 0, msg: "server error", data: "" });
  assert.ok(d.logs.some((l) => l.includes("connection refused")));
  assert.ok(!d.logs.some((l) => l.includes("SECRET-TOKEN")));
});

test("a body that is not ours (garbage, wrong key, not JSON) is a 400", async () => {
  const d = deps(async () => ({}));
  assert.equal((await handle("updateBalance", "garbage!!", d)).status, 400);
  const other = pair();
  assert.equal((await handle("updateBalance", encryptBigData(loadPublicKey(spki(other.publicKey)), "{}"), d)).status, 400);
  assert.equal((await handle("updateBalance", encryptBigData(merchantPub, "not json"), d)).status, 400);
  assert.equal(d.calls.length, 0);
});

test("an unknown route is a 404", async () => {
  assert.equal((await handle("somethingElse", "x", deps(async () => ({})))).status, 404);
});

test("updateGameList: the list is saved with the platform's own links, then pictures are copied and the rows pointed at our copies", async () => {
  const rehosted: string[] = [];
  const set: string[] = [];
  const d = deps(async () => 2, {
    rehost: async (url, label) => {
      rehosted.push(`${label} <- ${url}`);
      return url.includes("broken") ? null : `https://ours/${label}.png`;
    },
    setImage: async (id, kind, from, to) => {
      set.push(`${id} ${kind} ${from} -> ${to}`);
    },
  });
  const list = [
    { id: 2883, merchantId: 1, name: "Teen Patti Gold", image: "https://t.example/a.png", banner: "https://t.example/b.png", gameIdentification: "kingdoms", status: 1 },
    { id: 2882, merchantId: 1, name: "Teen Patti", image: "https://t.example/broken.png", status: 1 },
    { id: null, name: "no id" },
    "junk",
  ];
  const r = await handle("updateGameList", request(list), d);
  assert.deepEqual(r.body, { code: 1, msg: "success", data: "" });
  const sent = d.calls[0][1].p_games;
  assert.equal(sent.length, 2);
  assert.equal(sent[0].image, "https://t.example/a.png", "saved first with the platform's link");
  assert.equal(sent[0].imageUrl, undefined);
  assert.equal(rehosted.length, 3);
  assert.deepEqual(set.sort(), [
    "2883 banner https://t.example/b.png -> https://ours/2883-banner.png",
    "2883 image https://t.example/a.png -> https://ours/2883-logo.png",
  ]);
  assert.ok(d.logs.some((l) => l.includes("2 of 3 pictures copied")));
});

test("updateGameList: the answer does not wait for the pictures when the runtime can keep working after it", async () => {
  let release: () => void = () => {};
  const gate = new Promise<void>((res) => (release = res));
  let background: Promise<unknown> | null = null;
  const set: string[] = [];
  const d = deps(async () => 1, {
    rehost: async (url) => {
      await gate; // a slow download
      return `${url}#ours`;
    },
    setImage: async (id, kind, _from, to) => {
      set.push(`${id} ${kind} ${to}`);
    },
    background: (work) => {
      background = work;
    },
  });
  const r = await handle("updateGameList", request([{ id: 1, name: "g", image: "https://t.example/a.png", banner: "https://t.example/b.png", status: 1 }]), d);
  assert.equal(r.body.code, 1); // answered while the pictures are still downloading
  assert.deepEqual(set, []);
  assert.ok(background, "the copying was handed to the runtime");
  release();
  await background;
  assert.equal(set.length, 2);
});

test("updateGameList: at most five pictures at a time, and one that fails or cannot be saved does not stop the rest", async () => {
  let running = 0;
  let peak = 0;
  const saved: number[] = [];
  const d = deps(async () => 12, {
    rehost: async (url) => {
      running++;
      peak = Math.max(peak, running);
      await new Promise((r) => setTimeout(r, 5));
      running--;
      return url.includes("bad") ? null : `${url}#ours`;
    },
    setImage: async (id) => {
      if (id === 3) throw new Error("db down");
      saved.push(id);
    },
  });
  const list = Array.from({ length: 12 }, (_, i) => ({ id: i + 1, name: `g${i}`, image: i === 1 ? "https://t.example/bad.png" : `https://t.example/${i}.png`, status: 1 }));
  const r = await handle("updateGameList", request(list), d);
  assert.equal(r.body.code, 1);
  assert.ok(peak <= 5, `peak ${peak}`);
  assert.equal(saved.length, 10); // 12 - the failed copy (id 2) - the failed save (id 3)
});

test("updateGameList: a picture path that starts with / is completed with the picture host before it is saved and copied", async () => {
  const copied: string[] = [];
  const d = deps(async () => 1, {
    imageBase: "https://cos.example/",
    rehost: async (url) => {
      copied.push(url);
      return null;
    },
    setImage: async () => {},
  });
  await handle("updateGameList", request([{ id: 1, name: "g", image: "/upload/a.png", banner: "https://other.example/b.png", status: 1 }]), d);
  assert.equal(d.calls[0][1].p_games[0].image, "https://cos.example/upload/a.png");
  assert.equal(d.calls[0][1].p_games[0].banner, "https://other.example/b.png", "a full link is left alone");
  assert.deepEqual(copied.sort(), ["https://cos.example/upload/a.png", "https://other.example/b.png"]);
});

test("updateGameList: not an array is refused, a long list is cut at 200", async () => {
  const d = deps(async () => 0);
  assert.equal((await handle("updateGameList", request({ gameList: [] }), d)).body.code, 0);
  const many = Array.from({ length: 300 }, (_, i) => ({ id: i + 1, name: `g${i}`, status: 1 }));
  await handle("updateGameList", request(many), d);
  assert.equal(d.calls[0][1].p_games.length, 200);
});
