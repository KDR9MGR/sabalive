// Pure helpers for the system-ops function (no network, no Deno APIs) so they can be unit-tested with plain Node.

export type Target = "production" | "staging";

/** One read-only query for the database KPIs. Run through the Management API's read-only SQL endpoint. */
export const KPI_SQL = `
select jsonb_build_object(
  'connections', (select count(*) from pg_stat_activity where datname = current_database()),
  'max_connections', (select setting::int from pg_settings where name = 'max_connections'),
  'active_queries', (select count(*) from pg_stat_activity where datname = current_database() and backend_type = 'client backend' and state = 'active' and pid <> pg_backend_pid()),
  'idle_in_transaction', (select count(*) from pg_stat_activity where datname = current_database() and state like 'idle in transaction%'),
  'longest_active_seconds', (select coalesce(max(extract(epoch from now() - query_start)), 0)::int from pg_stat_activity where datname = current_database() and backend_type = 'client backend' and state = 'active' and pid <> pg_backend_pid()),
  'db_size_bytes', pg_database_size(current_database()),
  'cache_hit_percent', (select round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 2) from pg_stat_database where datname = current_database()),
  'deadlocks', (select deadlocks from pg_stat_database where datname = current_database()),
  'uptime_seconds', (select extract(epoch from now() - pg_postmaster_start_time())::int),
  'profiles_estimate', (select n_live_tup from pg_stat_user_tables where schemaname = 'public' and relname = 'profiles'),
  'top_tables', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
      select relname as name, pg_total_relation_size(relid) as bytes, n_live_tup as rows
        from pg_stat_user_tables order by pg_total_relation_size(relid) desc limit 5) t)
) as kpis
`;

/** The phrase a person must type to restart a project. */
export const restartPhrase = (t: Target) => `RESTART ${t.toUpperCase()}`;

/** The database query endpoint answers with an array of rows; tolerate a few shapes. */
export function pickKpiRow(body: unknown): Record<string, unknown> | null {
  const rows = Array.isArray(body) ? body : (body as { result?: unknown })?.result;
  const first = Array.isArray(rows) ? rows[0] : null;
  const k = (first as { kpis?: unknown } | null)?.kpis;
  if (k && typeof k === "object") return k as Record<string, unknown>;
  if (typeof k === "string") { try { return JSON.parse(k); } catch { return null; } }
  return null;
}

/** Sum the per-service request counters from usage.api-counts (rows of total_*_requests over time). */
export function sumApiCounts(body: unknown) {
  const rows = (Array.isArray(body) ? body : (body as { result?: unknown })?.result) as Array<Record<string, unknown>> | undefined;
  const out = { auth: 0, realtime: 0, rest: 0, storage: 0, total: 0, buckets: 0 };
  if (!Array.isArray(rows)) return out;
  for (const r of rows) {
    out.buckets++;
    for (const [k, v] of Object.entries(r)) {
      const n = Number(v);
      if (!Number.isFinite(n)) continue;
      const m = /^total_(auth|realtime|rest|storage)_requests$/.exec(k);
      if (m) { out[m[1] as "auth" | "realtime" | "rest" | "storage"] += n; out.total += n; }
    }
  }
  return out;
}

/** Parse Prometheus text into samples for the few metrics we show (labels kept so a disk can be picked). */
export function parsePrometheus(text: string, wanted: string[]) {
  const want = new Set(wanted);
  const out: Record<string, Array<{ labels: Record<string, string>; value: number }>> = {};
  for (const line of text.split("\n")) {
    if (!line || line[0] === "#") continue;
    const m = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{([^}]*)\})?\s+(-?[0-9.eE+-]+|NaN|\+Inf|-Inf)/.exec(line);
    if (!m || !want.has(m[1])) continue;
    const value = Number(m[4]);
    if (!Number.isFinite(value)) continue;
    const labels: Record<string, string> = {};
    for (const p of (m[3] ?? "").matchAll(/([a-zA-Z_][a-zA-Z0-9_]*)="([^"]*)"/g)) labels[p[1]] = p[2];
    (out[m[1]] ??= []).push({ labels, value });
  }
  return out;
}

const pct = (used: number, total: number) => (total > 0 ? Math.round((used / total) * 1000) / 10 : null);

/** CPU load, memory and disk from node-exporter style metrics; any part may be missing (null). */
export function summariseMetrics(text: string) {
  const s = parsePrometheus(text, [
    "node_load1", "node_load5", "node_memory_MemTotal_bytes", "node_memory_MemAvailable_bytes",
    "node_filesystem_size_bytes", "node_filesystem_avail_bytes", "node_cpu_seconds_total",
  ]);
  const one = (n: string) => s[n]?.[0]?.value ?? null;
  const memTotal = one("node_memory_MemTotal_bytes");
  const memAvail = one("node_memory_MemAvailable_bytes");
  // the data disk: prefer /data, then /, else the largest filesystem
  const sizes = s["node_filesystem_size_bytes"] ?? [];
  const pick = sizes.find((x) => x.labels.mountpoint === "/data") ?? sizes.find((x) => x.labels.mountpoint === "/") ??
    [...sizes].sort((a, b) => b.value - a.value)[0];
  const avail = pick
    ? (s["node_filesystem_avail_bytes"] ?? []).find((x) => x.labels.mountpoint === pick.labels.mountpoint && x.labels.device === pick.labels.device)?.value ??
      (s["node_filesystem_avail_bytes"] ?? []).find((x) => x.labels.mountpoint === pick.labels.mountpoint)?.value ?? null
    : null;
  const cpus = new Set((s["node_cpu_seconds_total"] ?? []).map((x) => x.labels.cpu)).size || null;
  return {
    load1: one("node_load1"),
    load5: one("node_load5"),
    cpuCount: cpus,
    memTotalBytes: memTotal,
    memUsedPercent: memTotal != null && memAvail != null ? pct(memTotal - memAvail, memTotal) : null,
    diskMount: pick?.labels.mountpoint ?? null,
    diskTotalBytes: pick?.value ?? null,
    diskUsedPercent: pick && avail != null ? pct(pick.value - avail, pick.value) : null,
  };
}

export const ymd = (d: Date) => d.toISOString().slice(0, 10);

/** Agora wants UTC dates, and recommends leaving today out (it keeps changing). */
export function agoraRange(now = new Date()) {
  const yesterday = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - 1));
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const from = monthStart.getTime() > yesterday.getTime() ? new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1)) : monthStart;
  return { from: ymd(from), to: ymd(yesterday), monthStart: ymd(monthStart) };
}

/**
 * Agora's usage reply is a list of days; each day carries duration fields in SECONDS
 * (durationAudioAll, durationVideoHD, durationVideo1080P, ...). We read them tolerantly:
 * any numeric key starting with "duration" is a duration, "audio" in the name is audio, else video.
 */
export function parseAgoraUsage(body: unknown, monthStart: string) {
  const root = body as Record<string, unknown> | null;
  const list = (root?.usages ?? root?.usage ?? root?.data ?? (Array.isArray(body) ? body : [])) as unknown;
  const days: Array<{ date: string; audioMin: number; videoMin: number; totalMin: number }> = [];
  if (Array.isArray(list)) {
    for (const d of list as Array<Record<string, unknown>>) {
      const date = String(d.date ?? d.day ?? "").slice(0, 10);
      const src = (typeof d.usage === "object" && d.usage ? d.usage : d) as Record<string, unknown>;
      let audio = 0, video = 0;
      for (const [k, v] of Object.entries(src)) {
        if (!/^duration/i.test(k)) continue;
        const n = Number(v);
        if (!Number.isFinite(n)) continue;
        if (/all$/i.test(k)) { if (/audio/i.test(k)) audio = Math.max(audio, n); continue; }
        if (/audio/i.test(k)) audio += n; else video += n;
      }
      if (date) days.push({ date, audioMin: Math.round(audio / 60), videoMin: Math.round(video / 60), totalMin: Math.round((audio + video) / 60) });
    }
  }
  days.sort((a, b) => a.date.localeCompare(b.date));
  const sum = (rows: typeof days) => rows.reduce((s, r) => ({ audioMin: s.audioMin + r.audioMin, videoMin: s.videoMin + r.videoMin, totalMin: s.totalMin + r.totalMin }), { audioMin: 0, videoMin: 0, totalMin: 0 });
  return { days: days.slice(-14), monthToDate: sum(days.filter((d) => d.date >= monthStart)), last7: sum(days.slice(-7)) };
}
