// deno-lint-ignore-file no-explicit-any
// What Tulasi calls on our side, kept free of any network or Deno API so it can be tested: the Edge Function (index.ts)
// supplies the keys and a function that runs our database functions.
//
//   POST .../userInformation   {token, gameType, ...}            -> {id, coin, gameCoin, nickname, avatar}
//   POST .../updateBalance     {token, uid, transactionId, type, coin, ...} -> {id, coin}
//   POST .../updateGameList    [{id, name, image, banner, ...}]  -> (empty data)
//
// The request body is an RSA-encrypted string (see rsa.ts). The reply is JSON {code, msg, data}: code 1 = success, and
// `data` is the answer encrypted with the PLATFORM's public key. A refusal is code 0 with a short msg and no data.
import { decryptBigData, decryptPath, encryptBigData } from "./rsa.ts";

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<any>;

export interface Deps {
  privateKey: any;
  platformPublicKey: any;
  rpc: Rpc;
  /** Copies a picture to our own storage and returns its public URL (null if it could not). */
  rehost?: (url: string, label: string) => Promise<string | null>;
  /** Points a game's picture at our copy, only if the row still holds [from] (a newer sync must not be undone). */
  setImage?: (id: number, kind: "image" | "banner", from: string, to: string) => Promise<void>;
  /** Where a picture path that starts with "/" lives (the Request Tester sends paths, the real push sends full links). */
  imageBase?: string;
  /** Keeps work running after the answer has been sent (EdgeRuntime.waitUntil). Without it the work is awaited. */
  background?: (work: Promise<unknown>) => void;
  log?: (message: string) => void;
}

export interface Reply {
  status: number;
  body: { code: number; msg: string; data: string };
}

const ok = (data: string): Reply => ({ status: 200, body: { code: 1, msg: "success", data } });
const refuse = (msg: string): Reply => ({ status: 200, body: { code: 0, msg, data: "" } });
const bad = (msg: string, status = 400): Reply => ({ status, body: { code: 0, msg, data: "" } });

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const asNum = (v: unknown): number | null => {
  if (isNum(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return null;
};

/** The last path segment of the request URL, e.g. "/functions/v1/tulasi/userInformation" -> "userInformation". */
export function routeOf(pathname: string): string {
  return pathname.replace(/\/+$/, "").split("/").pop() ?? "";
}

export async function handle(route: string, body: string, deps: Deps): Promise<Reply> {
  const log = deps.log ?? (() => {});
  if (route !== "userInformation" && route !== "updateBalance" && route !== "updateGameList") {
    return bad("not found", 404);
  }

  let plain: any;
  try {
    const t0 = Date.now();
    plain = JSON.parse(decryptBigData(deps.privateKey, body.trim()));
    log(`${route}: body of ${body.length} characters decrypted (${decryptPath}) in ${Date.now() - t0} ms`);
  } catch (_) {
    log(`${route}: body could not be decrypted or parsed`);
    return bad("bad request");
  }

  try {
    if (route === "userInformation") return await userInformation(plain, deps);
    if (route === "updateBalance") return await updateBalance(plain, deps);
    return await updateGameList(plain, deps);
  } catch (e) {
    log(`${route}: ${(e as Error).message}`);
    return bad("server error", 500);
  }
}

async function userInformation(req: any, deps: Deps): Promise<Reply> {
  if (!req || typeof req.token !== "string" || req.token === "") return refuse("token is required");
  const r = await deps.rpc("game_get_user", { p_token: req.token });
  if (!r?.ok) return refuse(String(r?.msg ?? "failed"));
  const data = {
    id: r.id,
    coin: r.coin,
    gameCoin: r.gameCoin ?? 0,
    nickname: r.nickname ?? "",
    avatar: r.avatar ?? "",
  };
  return ok(encryptBigData(deps.platformPublicKey, JSON.stringify(data)));
}

async function updateBalance(req: any, deps: Deps): Promise<Reply> {
  if (!req || typeof req.token !== "string" || req.token === "") return refuse("token is required");
  const uid = asNum(req.uid);
  const type = asNum(req.type);
  const coin = asNum(req.coin);
  const timestamp = asNum(req.timestamp);
  const transactionId = req.transactionId == null ? "" : String(req.transactionId);
  if (uid === null || type === null || !Number.isInteger(type)) return refuse("uid and type are required");
  if (transactionId === "") return refuse("transactionId is required");
  if (type === 0 || type === 1) {
    if (coin === null || !Number.isInteger(coin) || coin < 0) return refuse("coin must be a whole number");
  }
  const r = await deps.rpc("game_apply_balance", {
    p_token: req.token,
    p_uid: uid,
    p_transaction_id: transactionId,
    p_type: type,
    p_coin: coin ?? 0,
    p_game_id: req.gameId == null ? null : String(req.gameId),
    p_game_type: req.gameType == null ? null : String(req.gameType),
    p_timestamp: timestamp,
    p_game_start: asNum(req.gameStartTimestamp),
    p_game_end: asNum(req.gameEndTimestamp),
    p_ext: req.ext == null ? null : String(req.ext),
    p_remark: req.remark == null ? null : String(req.remark),
  });
  if (!r?.ok) return refuse(String(r?.msg ?? "failed"));
  return ok(encryptBigData(deps.platformPublicKey, JSON.stringify({ id: r.id ?? uid, coin: r.coin })));
}

async function updateGameList(list: any, deps: Deps): Promise<Reply> {
  if (!Array.isArray(list)) return refuse("the game list must be an array");
  const log = deps.log ?? (() => {});
  const base = (deps.imageBase ?? "").replace(/\/+$/, "");
  const full = (v: unknown) => (typeof v === "string" && v.startsWith("/") && base ? base + v : v);
  const games = list
    .slice(0, 200)
    .filter((g) => g && g.id != null && typeof g.name === "string")
    .map((g) => ({ ...g, image: full(g.image), banner: full(g.banner) }));
  // The list itself first, and answered at once: the platform waits only a few seconds for our reply (copying the pictures one by
  // one took 15 s and it reported "Sync game list fail"). The pictures are copied after the answer; until then the app shows the
  // platform's own links, then our copies.
  await deps.rpc("game_sync_list", { p_games: games });
  log(`updateGameList: ${games.length} games saved`);
  if (deps.rehost && deps.setImage) {
    const work = copyPictures(games, deps.rehost, deps.setImage, log);
    if (deps.background) deps.background(work);
    else await work;
  }
  return ok("");
}

/** Copies every game's logo and banner to our storage, a few at a time, and points the rows at the copies. Never throws. */
async function copyPictures(
  games: any[],
  rehost: NonNullable<Deps["rehost"]>,
  setImage: NonNullable<Deps["setImage"]>,
  log: (message: string) => void,
): Promise<void> {
  const jobs: Array<() => Promise<boolean>> = [];
  for (const g of games) {
    for (const [kind, label] of [["image", "logo"], ["banner", "banner"]] as const) {
      const from = g[kind];
      if (typeof from !== "string" || from === "") continue;
      jobs.push(async () => {
        const to = await rehost(from, `${g.id}-${label}`).catch(() => null);
        if (!to) return false;
        await setImage(Number(g.id), kind, from, to);
        return true;
      });
    }
  }
  let next = 0;
  let copied = 0;
  const worker = async () => {
    while (next < jobs.length) {
      const job = jobs[next++];
      if (await job().catch(() => false)) copied++;
    }
  };
  await Promise.all(Array.from({ length: Math.min(5, jobs.length) }, worker));
  log(`updateGameList: ${copied} of ${jobs.length} pictures copied to our storage`);
}
