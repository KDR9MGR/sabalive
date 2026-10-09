// System KPIs and restart for the admin panel (Super Admin → System Overview, Master → System Management).
//
//   POST { "action": "kpis" }
//     -> { configured, generatedAt, production, staging, agora, app }
//        production / staging: Supabase project status, service health, database numbers (connections vs the limit, size,
//        cache hit, slow queries, top tables), API request counts, CPU / memory / disk when the metrics endpoint answers.
//        agora: usage minutes (audio / video) month to date and the last days, from Agora's Console usage API.
//        app: live rooms and viewers right now, read from this project's own tables.
//   POST { "action": "restart", "target": "production" | "staging", "confirm": "RESTART PRODUCTION" | "RESTART STAGING" }
//     -> restarts that Supabase project through the Management API.
//
// WHO: the caller must be a signed-in staff account (JWT checked with auth.getUser()). KPIs: a Super Admin, or any
// account with the manage_system / manage_infra switch on. Restart: a Super Admin, or a Master (role admin) with
// manage_system on — never anyone else, whatever else they were granted.
// SAFEGUARDS (restart): the exact confirm phrase, one restart per target per 15 minutes, every attempt audit-logged.
//
// SECRETS (Edge Functions → Secrets; set by a person, never in the repo or the panel):
//   SUPABASE_ACCESS_TOKEN   a Supabase personal access token (account → Access Tokens) that can see BOTH projects
//   PROD_PROJECT_REF        optional, default sfehzhtqtpuobnrvzvzp
//   STAGING_PROJECT_REF     optional, default gsloixbaktefwgxzjtps
//   AGORA_CUSTOMER_ID, AGORA_CUSTOMER_SECRET   Agora Console → Developer Toolkit → RESTful API
//   AGORA_PROJECT_ID        the Agora *project id* (not the App ID) used by the usage API
// A missing secret never breaks the function: that section just reports it is not configured.

import { createClient } from "npm:@supabase/supabase-js@2";
import { agoraRange, KPI_SQL, parseAgoraUsage, pickKpiRow, restartPhrase, sumApiCounts, summariseMetrics, type Target } from "./kpi.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PAT = Deno.env.get("SUPABASE_ACCESS_TOKEN") ?? "";
const REFS: Record<Target, string> = {
  production: Deno.env.get("PROD_PROJECT_REF") || "sfehzhtqtpuobnrvzvzp",
  staging: Deno.env.get("STAGING_PROJECT_REF") || "gsloixbaktefwgxzjtps",
};
const AGORA_ID = Deno.env.get("AGORA_CUSTOMER_ID") ?? "";
const AGORA_SECRET = Deno.env.get("AGORA_CUSTOMER_SECRET") ?? "";
const AGORA_PROJECT = Deno.env.get("AGORA_PROJECT_ID") ?? "";
const RESTART_COOLDOWN_MIN = 15;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MGMT = "https://api.supabase.com";
async function mgmt(path: string, init: RequestInit = {}, timeoutMs = 8000) {
  const res = await fetch(MGMT + path, {
    ...init,
    headers: { Authorization: `Bearer ${PAT}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await res.text();
  let body: unknown = text;
  try { body = JSON.parse(text); } catch { /* plain text (Prometheus) */ }
  return { ok: res.ok, status: res.status, body, text };
}

// one section failing must not take the others down
async function safe<T>(fn: () => Promise<T>): Promise<T | { error: string }> {
  try { return await fn(); } catch (e) { return { error: e instanceof Error ? e.message : String(e) }; }
}

async function envKpis(target: Target) {
  const ref = REFS[target];
  const [info, health, db, api, metrics] = await Promise.all([
    safe(async () => {
      const r = await mgmt(`/v1/projects/${ref}`);
      if (!r.ok) throw new Error(`project info ${r.status}`);
      const b = r.body as Record<string, unknown>;
      return { name: b.name ?? null, region: b.region ?? null, status: b.status ?? null, createdAt: b.created_at ?? null };
    }),
    safe(async () => {
      const r = await mgmt(`/v1/projects/${ref}/health?services=auth,db,pooler,realtime,rest,storage&timeout_ms=5000`, {}, 9000);
      if (!r.ok) throw new Error(`health ${r.status}`);
      const list = Array.isArray(r.body) ? r.body : [];
      return list.map((s: Record<string, unknown>) => ({ service: String(s.name ?? ""), healthy: s.healthy === true, status: String(s.status ?? "") }));
    }),
    safe(async () => {
      const r = await mgmt(`/v1/projects/${ref}/database/query/read-only`, { method: "POST", body: JSON.stringify({ query: KPI_SQL }) }, 10000);
      if (!r.ok) throw new Error(`database ${r.status}`);
      const k = pickKpiRow(r.body);
      if (!k) throw new Error("database: unexpected answer");
      return k;
    }),
    safe(async () => {
      const r = await mgmt(`/v1/projects/${ref}/analytics/endpoints/usage.api-counts?interval=1day`, {}, 9000);
      if (!r.ok) throw new Error(`api counts ${r.status}`);
      return sumApiCounts(r.body);
    }),
    safe(async () => {
      const r = await mgmt(`/v1/projects/${ref}/analytics/endpoints/metrics`, {}, 9000);
      if (!r.ok) throw new Error(`metrics ${r.status}`);
      return summariseMetrics(r.text);
    }),
  ]);
  return { ref, info, health, database: db, api, resources: metrics };
}

async function agoraUsage() {
  if (!AGORA_ID || !AGORA_SECRET || !AGORA_PROJECT) return { configured: false };
  const { from, to, monthStart } = agoraRange();
  const url = `https://api.agora.io/dev/v3/usage?project_id=${encodeURIComponent(AGORA_PROJECT)}&from_date=${from}&to_date=${to}&business=default`;
  const res = await fetch(url, {
    headers: { Authorization: "Basic " + btoa(`${AGORA_ID}:${AGORA_SECRET}`) },
    signal: AbortSignal.timeout(9000),
  });
  const text = await res.text();
  if (!res.ok) return { configured: true, error: `Agora answered ${res.status}: ${text.slice(0, 200)}` };
  let body: unknown = null;
  try { body = JSON.parse(text); } catch { return { configured: true, error: "Agora answered with something that is not JSON" }; }
  return { configured: true, from, to, ...parseAgoraUsage(body, monthStart) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!SUPABASE_URL || !SERVICE_KEY) return json({ error: "Function is not configured" }, 500);

  // who is asking
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
  const { data: u } = await userClient.auth.getUser();
  if (!u?.user) return json({ error: "Sign in first" }, 401);
  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const { data: staff } = await admin.from("staff_roles").select("role, permissions").eq("user_id", u.user.id).maybeSingle();
  if (!staff) return json({ error: "Staff only" }, 403);
  const perms = (staff.permissions ?? {}) as Record<string, unknown>;
  const isSuper = staff.role === "super_admin";
  const canView = isSuper || perms.manage_system === true || perms.manage_infra === true;
  const canRestart = isSuper || (staff.role === "admin" && perms.manage_system === true);

  let body: { action?: string; target?: string; confirm?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }

  if (body.action === "kpis") {
    if (!canView) return json({ error: "Your account does not have System access" }, 403);
    const [production, staging, agora, live] = await Promise.all([
      PAT ? envKpis("production") : Promise.resolve({ configured: false }),
      PAT ? envKpis("staging") : Promise.resolve({ configured: false }),
      safe(agoraUsage),
      safe(async () => {
        const { data, error } = await admin.from("live_streams").select("viewer_count").eq("status", "live");
        if (error) throw new Error(error.message);
        return { liveRooms: data?.length ?? 0, viewers: (data ?? []).reduce((s, r) => s + Number(r.viewer_count ?? 0), 0) };
      }),
    ]);
    return json({
      generatedAt: new Date().toISOString(),
      configured: { supabase: !!PAT, agora: !!(AGORA_ID && AGORA_SECRET && AGORA_PROJECT) },
      canRestart,
      refs: REFS,
      production, staging, agora, app: live,
    });
  }

  if (body.action === "restart") {
    if (!canRestart) return json({ error: "Only a Super Admin, or a Master with System management, can restart a project" }, 403);
    const target = body.target as Target;
    if (target !== "production" && target !== "staging") return json({ error: "Unknown target" }, 400);
    if (body.confirm !== restartPhrase(target)) return json({ error: `Type ${restartPhrase(target)} to confirm` }, 400);
    if (!PAT) return json({ error: "SUPABASE_ACCESS_TOKEN is not set on the function" }, 500);

    const since = new Date(Date.now() - RESTART_COOLDOWN_MIN * 60000).toISOString();
    const { data: recent } = await admin.from("audit_logs").select("id").eq("action", "system.restart").like("target", `${target}%`).gte("created_at", since).limit(1);
    if (recent && recent.length) return json({ error: `${target} was restarted in the last ${RESTART_COOLDOWN_MIN} minutes — wait before trying again` }, 429);

    const ref = REFS[target];
    await admin.from("audit_logs").insert({ actor_id: u.user.id, action: "system.restart", target: `${target} (${ref})`, severity: "critical" });
    const r = await mgmt(`/v1/projects/${ref}/restart`, { method: "POST" }, 15000);
    if (!r.ok) {
      await admin.from("audit_logs").insert({ actor_id: u.user.id, action: "system.restart_failed", target: `${target} (${ref}) → ${r.status}`, severity: "warning" });
      return json({ error: `Supabase refused the restart (${r.status})` }, 502);
    }
    return json({ ok: true, target, message: `${target} is restarting. It can take a minute or two; the panel may be briefly unavailable.` });
  }

  return json({ error: "Unknown action" }, 400);
});
