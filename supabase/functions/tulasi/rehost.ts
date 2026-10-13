// deno-lint-ignore-file no-explicit-any
// Copies a game's picture to our own storage (Tulasi says its URLs may change): https only, no IP addresses or
// internal names, at most 2 MB, an image content type, 5 seconds. Returns our public URL, or null on any problem.
export interface RehostDeps {
  fetchFn: (url: string, init: { signal: AbortSignal; redirect: "error" }) => Promise<Response>;
  upload: (path: string, bytes: Uint8Array, contentType: string) => Promise<string | null>;
}

const MAX_BYTES = 2 * 1024 * 1024;
const EXT: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif" };

export function isSafeImageUrl(raw: string): boolean {
  let u: URL;
  try {
    u = new URL(raw);
  } catch (_) {
    return false;
  }
  if (u.protocol !== "https:" || u.username || u.password) return false;
  const h = u.hostname.toLowerCase();
  if (!h.includes(".") || h === "localhost" || h.endsWith(".local") || h.endsWith(".internal")) return false;
  if (/^[0-9.]+$/.test(h) || h.includes(":") || h.startsWith("[")) return false; // IP literals
  return true;
}

export function makeRehost(deps: RehostDeps) {
  return async (url: string, label: string): Promise<string | null> => {
    if (!isSafeImageUrl(url)) return null;
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 5000);
    try {
      const res = await deps.fetchFn(url, { signal: ctl.signal, redirect: "error" });
      if (!res.ok) return null;
      const type = (res.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
      const ext = EXT[type];
      if (!ext) return null;
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (bytes.length === 0 || bytes.length > MAX_BYTES) return null;
      const digest = await crypto.subtle.digest("SHA-256", bytes);
      const hash = Array.from(new Uint8Array(digest)).slice(0, 8).map((b) => b.toString(16).padStart(2, "0")).join("");
      const safe = label.replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 40) || "img";
      return await deps.upload(`games/${safe}-${hash}.${ext}`, bytes, type);
    } catch (_) {
      return null;
    } finally {
      clearTimeout(timer);
    }
  };
}
