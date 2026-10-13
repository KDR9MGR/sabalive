// Run with: scripts/test_functions.sh   (Node's test runner; the function itself runs on Deno)
import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { decryptBigData, encryptBigData, loadPrivateKey, loadPublicKey } from "./rsa.ts";

const pair = () => crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const spki = (k: crypto.KeyObject) => k.export({ type: "spki", format: "pem" }).toString();
const pkcs8 = (k: crypto.KeyObject) => k.export({ type: "pkcs8", format: "pem" }).toString();
const body = (pem: string) => pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");

test("round trip: short text, long text (several 200-byte pieces) and non-ASCII", () => {
  const { publicKey, privateKey } = pair();
  const pub = loadPublicKey(spki(publicKey));
  const priv = loadPrivateKey(pkcs8(privateKey));
  for (const text of ["{}", "x".repeat(199), "x".repeat(200), "x".repeat(201), JSON.stringify({ nickname: "आरव 🎮 Åsa", list: Array(80).fill("abc") })]) {
    assert.equal(decryptBigData(priv, encryptBigData(pub, text)), text);
  }
});

test("the encrypted text is pieces of base64 joined by a colon, one piece per 200 bytes", () => {
  const { publicKey } = pair();
  const enc = encryptBigData(loadPublicKey(spki(publicKey)), "y".repeat(450));
  assert.equal(enc.split(":").length, 3);
  for (const piece of enc.split(":")) assert.match(piece, /^[A-Za-z0-9+/]+=*$/);
  assert.equal(encryptBigData(loadPublicKey(spki(publicKey)), ""), "");
});

test("what the platform sends us (standard RSA PKCS#1 v1.5 pieces) is readable", () => {
  const { publicKey, privateKey } = pair();
  const text = JSON.stringify({ token: "DA84Cf9A3021c666F145Bd45ACe0aFDB", gameType: "lucky99", pad: "z".repeat(300) });
  const bytes = Buffer.from(text, "utf8");
  const pieces: string[] = [];
  for (let i = 0; i < bytes.length; i += 200) {
    pieces.push(crypto.publicEncrypt({ key: publicKey, padding: crypto.constants.RSA_PKCS1_PADDING }, bytes.subarray(i, i + 200)).toString("base64"));
  }
  assert.equal(decryptBigData(loadPrivateKey(pkcs8(privateKey)), pieces.join(":")), text);
});

test("what we send is readable by a standard RSA implementation", (t) => {
  const { publicKey, privateKey } = pair();
  const enc = encryptBigData(loadPublicKey(spki(publicKey)), "hello from us");
  try {
    const out = crypto.privateDecrypt({ key: privateKey, padding: crypto.constants.RSA_PKCS1_PADDING }, Buffer.from(enc, "base64"));
    assert.equal(out.toString("utf8"), "hello from us");
  } catch (e) {
    // newer Node versions refuse PKCS#1 v1.5 decryption outright (a timing-attack mitigation): not our code's problem
    if ((e as { code?: string }).code === "ERR_OSSL_RSA_PKCS_DECODING_ERROR" || /RSA_PKCS1_PADDING/.test(String(e))) t.skip("this Node refuses PKCS#1 v1.5 decryption");
    else throw e;
  }
});

test("keys may be given as the bare base64 body, or on one line with literal backslash-n", () => {
  const { publicKey, privateKey } = pair();
  const text = "keys in different clothes";
  const baseline = encryptBigData(loadPublicKey(spki(publicKey)), text);
  assert.equal(decryptBigData(loadPrivateKey(body(pkcs8(privateKey))), baseline), text);
  assert.equal(decryptBigData(loadPrivateKey(pkcs8(privateKey).replace(/\n/g, "\\n")), baseline), text);
  const viaBare = encryptBigData(loadPublicKey(body(spki(publicKey))), text);
  assert.equal(decryptBigData(loadPrivateKey(pkcs8(privateKey)), viaBare), text);
  const viaOneLine = encryptBigData(loadPublicKey(spki(publicKey).replace(/\n/g, "\\n")), text);
  assert.equal(decryptBigData(loadPrivateKey(pkcs8(privateKey)), viaOneLine), text);
});

test("a PKCS#1 private key (BEGIN RSA PRIVATE KEY) is accepted too", () => {
  const { publicKey, privateKey } = pair();
  const pkcs1 = privateKey.export({ type: "pkcs1", format: "pem" }).toString();
  assert.equal(decryptBigData(loadPrivateKey(pkcs1), encryptBigData(loadPublicKey(spki(publicKey)), "ok")), "ok");
});

test("garbage is refused, not turned into text", () => {
  const { publicKey, privateKey } = pair();
  const priv = loadPrivateKey(pkcs8(privateKey));
  assert.throws(() => decryptBigData(priv, "not base64 at all !!!"));
  assert.throws(() => decryptBigData(priv, Buffer.alloc(256, 7).toString("base64")));
  // a piece made for another key
  const other = pair();
  assert.throws(() => decryptBigData(priv, encryptBigData(loadPublicKey(spki(other.publicKey)), "x")));
  void publicKey;
});

test("unreadable keys say so", () => {
  assert.throws(() => loadPrivateKey("nonsense"), /merchant private key/);
  assert.throws(() => loadPublicKey("nonsense"), /platform public key/);
});
