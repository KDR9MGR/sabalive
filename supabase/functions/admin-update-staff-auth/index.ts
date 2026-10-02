// Lets a Master change a staff account's LOGIN email and/or password. The
// admin panel only holds the anon key and cannot call auth.admin.*, so this
// runs with the service-role key, which never leaves the server.
//
// Who may do it is decided in SQL (assert_can_manage_staff): the caller must
// be a Master (staff_roles.role = 'admin'), the target must be a
// global_admin / country_admin / sub_admin / agency_manager, and never the
// caller themselves. Profile fields (name, username, phone, ...) are NOT
// handled here — they go through the admin_update_staff_profile RPC, which
// has to run as the caller so the username-lock trigger lets the change in.
//
// Request body:
//   { "user_id": uuid,
//     "email"?: string,       // new login email (marked confirmed)
//     "password"?: string }   // new password, 8-72 chars
//
// Response: { "ok": true, "changed": ["email" | "password", ...] }

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!SERVICE_ROLE_KEY) return json({ error: "Server is missing SUPABASE_SERVICE_ROLE_KEY" }, 500);

  // 1. who is calling?
  const authHeader = req.headers.get("Authorization") ?? "";
  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await caller.auth.getUser();
  if (authError || !user) return json({ error: "You must be signed in" }, 401);

  // 2. validate the request
  let body: { user_id?: string; email?: string; password?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const targetId = body.user_id?.trim();
  const email = body.email?.trim().toLowerCase() || undefined;
  const password = body.password || undefined;

  if (!targetId || !UUID_RE.test(targetId)) return json({ error: "A valid user_id is required" }, 400);
  if (!email && !password) return json({ error: "Nothing to change — give an email and/or a password" }, 400);
  if (email && (!email.includes("@") || email.length > 254)) return json({ error: "A valid email is required" }, 400);
  if (password && (password.length < 8 || password.length > 72)) {
    return json({ error: "Password must be 8-72 characters" }, 400);
  }

  // 3. may THIS caller manage THAT account? (the rule lives in SQL)
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { error: checkErr } = await admin.rpc("assert_can_manage_staff", {
    p_actor: user.id,
    p_target: targetId,
  });
  if (checkErr) return json({ error: checkErr.message }, 403);

  // 4. apply
  const attrs: { email?: string; email_confirm?: boolean; password?: string } = {};
  if (email) {
    attrs.email = email;
    attrs.email_confirm = true;
  }
  if (password) attrs.password = password;

  const { error: updateErr } = await admin.auth.admin.updateUserById(targetId, attrs);
  if (updateErr) return json({ error: updateErr.message }, 400);

  const changed = [email ? "email" : null, password ? "password" : null].filter(Boolean) as string[];
  // Never log the password itself — only that it changed.
  await admin.from("audit_logs").insert({
    actor_id: user.id,
    action: "staff.credentials_changed",
    target: `${targetId} (${changed.join(" + ")})`,
    severity: "warning",
  });

  return json({ ok: true, changed });
});
