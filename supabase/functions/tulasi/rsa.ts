// deno-lint-ignore-file no-explicit-any
// RSA the way the Tulasi platform does it: PKCS#1 v1.5, the text split into 200-byte pieces, each piece encrypted and
// base64-encoded, the pieces joined with ":". Requests to us are encrypted with OUR public key (we decrypt with our private
// key); our answers are encrypted with THEIR public key. Keys come in as PEM text, or just the base64 body without the
// "-----BEGIN" lines, or a single line with literal "\n" (how a secret often ends up).
import forge from "node-forge";
import { Buffer } from "node:buffer";
import { constants, privateDecrypt } from "node:crypto";

const SPLIT_SIZE = 200;
const SPLIT = ":";

function pemOf(raw: string, label: string): string {
  let t = raw.trim().replace(/\\n/g, "\n");
  if (t.includes("-----BEGIN")) return t;
  t = t.replace(/\s+/g, "");
  return `-----BEGIN ${label}-----\n${(t.match(/.{1,64}/g) ?? []).join("\n")}\n-----END ${label}-----`;
}

export function loadPrivateKey(raw: string): any {
  let why = "";
  for (const label of ["PRIVATE KEY", "RSA PRIVATE KEY"]) {
    try {
      return (forge as any).pki.privateKeyFromPem(pemOf(raw, label));
    } catch (e) {
      why = (e as Error).message; // try the next label; forge's message names no key material
    }
  }
  throw new Error(`could not read the merchant private key (${why})`);
}

export function loadPublicKey(raw: string): any {
  let why = "";
  for (const label of ["PUBLIC KEY", "RSA PUBLIC KEY"]) {
    try {
      return (forge as any).pki.publicKeyFromPem(pemOf(raw, label));
    } catch (e) {
      why = (e as Error).message;
    }
  }
  throw new Error(`could not read the platform public key (${why})`);
}

/** Encrypts [text] (any length, any characters) for the key's owner. */
export function encryptBigData(publicKey: any, text: string): string {
  const bytes: string = (forge as any).util.encodeUtf8(text);
  const out: string[] = [];
  for (let i = 0; i < bytes.length; i += SPLIT_SIZE) {
    out.push((forge as any).util.encode64(publicKey.encrypt(bytes.slice(i, i + SPLIT_SIZE), "RSAES-PKCS1-V1_5")));
  }
  return out.join(SPLIT);
}

// The platform's full game list is about 150 pieces. node-forge decrypts one in roughly 25 ms (pure JavaScript), which is more CPU
// than an Edge Function request may use (the platform's push failed with WORKER_RESOURCE_LIMIT), so the runtime's native RSA is
// used when it allows PKCS#1 v1.5 for private decryption, and node-forge only when it does not (Node refuses that padding since
// the Marvin-attack fix; the unit tests then run the forge path).
const nativeKeys = new WeakMap<object, string>();
let nativeUsable: boolean | null = null;

/** The key as a PKCS#8 PEM string, the form every runtime's native RSA accepts. */
function nativeKeyOf(privateKey: any): string {
  let k = nativeKeys.get(privateKey);
  if (!k) {
    const f: any = forge;
    k = f.pki.privateKeyInfoToPem(f.pki.wrapRsaPrivateKey(f.pki.privateKeyToAsn1(privateKey)));
    nativeKeys.set(privateKey, k);
  }
  return k;
}

function decryptNative(privateKey: any, parts: string[]): string {
  const key = nativeKeyOf(privateKey);
  const out: Buffer[] = [];
  for (const p of parts) out.push(privateDecrypt({ key, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(p, "base64")));
  return new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(out));
}

function decryptForge(privateKey: any, parts: string[]): string {
  let bytes = "";
  for (const p of parts) bytes += privateKey.decrypt((forge as any).util.decode64(p), "RSAES-PKCS1-V1_5");
  return (forge as any).util.decodeUtf8(bytes);
}

/** Which implementation the last successful decrypt used (for the logs). */
export let decryptPath: "native" | "forge" | "none" = "none";
/** Why the native path was not used (for the logs; never key material). */
export let nativeError = "";

/** The reverse. Throws if any piece does not decrypt. */
export function decryptBigData(privateKey: any, encrypted: string): string {
  const parts = encrypted.split(SPLIT).map((p) => p.trim()).filter((p) => p !== "");
  if (nativeUsable !== false) {
    try {
      const text = decryptNative(privateKey, parts);
      nativeUsable = true;
      decryptPath = "native";
      return text;
    } catch (e) {
      nativeError = String((e as Error)?.message ?? e).slice(0, 160);
      // Not usable here (padding refused, no such API): remember it and use forge. A body that is simply not ours also lands here once
      // and fails in forge below, without marking the native path unusable.
      if (nativeUsable === null && /no longer supported|not supported|unsupported|not implemented|ERR_INVALID_ARG_VALUE/i.test(String((e as Error)?.message ?? e))) {
        nativeUsable = false;
      }
    }
  }
  const text = decryptForge(privateKey, parts);
  decryptPath = "forge";
  return text;
}
