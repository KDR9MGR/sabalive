import test from "node:test";
import assert from "node:assert/strict";
import { isSafeImageUrl, makeRehost } from "./rehost.ts";

test("only public https picture URLs are fetched", () => {
  for (const ok of ["https://static.example.com/a.png", "https://cdn.tulasigame.com/g/lucky99.webp?v=2"]) assert.equal(isSafeImageUrl(ok), true, ok);
  for (const bad of [
    "http://static.example.com/a.png", "https://localhost/a.png", "https://127.0.0.1/a.png", "https://10.0.0.5/a.png", "https://[::1]/a.png",
    "https://intranet/a.png", "https://box.local/a.png", "https://svc.internal/a.png", "https://user:pw@example.com/a.png", "file:///etc/passwd", "not a url", "",
  ]) assert.equal(isSafeImageUrl(bad), false, bad);
});

const png = (n: number) => new Response(new Uint8Array(n).fill(1), { headers: { "content-type": "image/png" } });

test("a good picture is uploaded under games/ with a content hash, and our URL is returned", async () => {
  const uploads: Array<{ path: string; type: string; size: number }> = [];
  const rehost = makeRehost({
    fetchFn: async () => png(100),
    upload: async (path, bytes, type) => {
      uploads.push({ path, type, size: bytes.length });
      return `https://ours/${path}`;
    },
  });
  const url = await rehost("https://static.example.com/a.png", "2883 logo!");
  assert.match(url ?? "", /^https:\/\/ours\/games\/2883logo-[0-9a-f]{16}\.png$/);
  assert.deepEqual(uploads.map((u) => [u.type, u.size]), [["image/png", 100]]);
});

test("anything wrong gives null and uploads nothing: unsafe URL, not ok, not an image, too big, empty, a fetch that throws", async () => {
  const uploads: string[] = [];
  const upload = async (p: string) => {
    uploads.push(p);
    return "x";
  };
  const cases: Array<[string, () => Promise<Response>]> = [
    ["https://ok.example.com/a.png", async () => new Response("no", { status: 404 })],
    ["https://ok.example.com/a.png", async () => new Response("<html>", { headers: { "content-type": "text/html" } })],
    ["https://ok.example.com/a.png", async () => png(3 * 1024 * 1024)],
    ["https://ok.example.com/a.png", async () => png(0)],
    ["https://ok.example.com/a.png", async () => {
      throw new Error("boom");
    }],
  ];
  for (const [url, f] of cases) assert.equal(await makeRehost({ fetchFn: f, upload })(url, "x"), null);
  let fetched = 0;
  const guarded = makeRehost({ fetchFn: async () => (fetched++, png(10)), upload });
  assert.equal(await guarded("http://insecure.example.com/a.png", "x"), null);
  assert.equal(fetched, 0, "an unsafe URL is never even requested");
  assert.deepEqual(uploads, []);
});
