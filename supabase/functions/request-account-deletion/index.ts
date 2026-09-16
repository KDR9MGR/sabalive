// Public account-deletion request endpoint, called from the standalone web
// page (no app install, no sign-in) required by Google Play's Data safety /
// Account deletion policy and Apple App Store Guideline 5.1.1(v).
//
// Deliberately does NOT look up whether the email belongs to a real
// account — doing so would let a caller enumerate registered emails. It
// just logs the request; an admin (via the admin panel, service-role side)
// matches the email against `profiles` and carries out the deletion.
//
// Request body: { "email": string, "reason"?: string }
// Response body: { "ok": true }  — always, so the response itself never
// reveals whether the email is a real account.

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: "Server is not configured" }, 500);
  }

  let body: { email?: string; reason?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const email = body.email?.trim().toLowerCase();
  if (!email || !EMAIL_RE.test(email)) {
    return json({ error: "A valid email is required" }, 400);
  }
  const reason = body.reason?.trim().slice(0, 500) || null;

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Skip inserting a duplicate if this email already has a pending request
  // from the last 24h — keeps repeated form submits from piling up rows.
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data: recent } = await admin
    .from("account_deletion_requests")
    .select("id")
    .eq("email", email)
    .eq("status", "pending")
    .gte("requested_at", since)
    .limit(1);

  if (!recent || recent.length === 0) {
    const { error } = await admin.from("account_deletion_requests").insert({
      email,
      reason,
      source: "web",
    });
    if (error) {
      console.error("account_deletion_requests insert failed", error);
      return json({ error: "Could not record your request, please try again" }, 500);
    }
  }

  return json({ ok: true });
});
