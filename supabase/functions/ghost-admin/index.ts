// Creates and manages Ghost IDs — accounts that sign in to the app and watch live
// rooms invisibly, for monitoring. Super Admin only. The panel holds just the anon
// key and cannot call auth.admin.*, so this runs with the service-role key.
//
// A ghost is an ordinary auth user created with app_metadata.ghost = true.
// app_metadata can only be written server-side (never by the user, unlike
// user_metadata), and the new-user trigger copies the flag onto the profile the
// instant it exists — so a ghost is hidden from the moment it is created, and
// nobody can make themselves one by signing up with crafted metadata.
//
// Request body: { "action": ..., ...fields }
//   create        { label, notes?, email?, password? }
//                 -> { user_id, email, temp_password | null }
//                    email omitted -> a throwaway ghost-xxxx@ghost.sabalive.in is made;
//                    password omitted -> a strong one is generated and returned ONCE
//   set_password  { user_id, password? } -> { user_id, temp_password | null }
//   set_active    { user_id, active }    -> { ok }   (off = sign-in is blocked)
//   delete        { user_id }            -> { ok }
//
// Editing a ghost's label / notes needs no service role: the panel calls the
// update_ghost_account RPC directly.

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// ~100 years: how long a disabled ghost stays unable to sign in
const BANNED = "876000h";

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

function randomToken(len: number): string {
  const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(len));
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

function tempPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(18));
  return btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, "").slice(0, 20) + "aA1!";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!SERVICE_ROLE_KEY) return json({ error: "Server is missing SUPABASE_SERVICE_ROLE_KEY" }, 500);

  // 1. who is calling? Only a Super Admin.
  const authHeader = req.headers.get("Authorization") ?? "";
  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await caller.auth.getUser();
  if (authError || !user) return json({ error: "You must be signed in" }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: callerRole } = await admin
    .from("staff_roles").select("role").eq("user_id", user.id).maybeSingle();
  if (callerRole?.role !== "super_admin") {
    return json({ error: "Only a Super Admin can manage ghost accounts" }, 403);
  }

  let body: {
    action?: string; label?: string; notes?: string; email?: string;
    password?: string; user_id?: string; active?: boolean;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const audit = (action: string, target: string, severity = "warning") =>
    admin.from("audit_logs").insert({ actor_id: user.id, action, target, severity });

  // ---------------------------------------------------------------- create
  if (body.action === "create") {
    const label = body.label?.trim();
    if (!label) return json({ error: "Give the ghost a label" }, 400);
    const email = (body.email?.trim().toLowerCase()) || `ghost-${randomToken(10)}@ghost.sabalive.in`;
    if (!email.includes("@")) return json({ error: "A valid email is required" }, 400);
    if (body.password && (body.password.length < 8 || body.password.length > 72)) {
      return json({ error: "Password must be 8-72 characters" }, 400);
    }
    const generated = !body.password;
    const password = body.password || tempPassword();

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      app_metadata: { ghost: true },
      // the profile row is seeded from here; a ghost profile is never shown to anyone
      user_metadata: { name: label, username: `ghost_${randomToken(8)}` },
    });
    if (createErr || !created?.user) {
      return json({ error: createErr?.message || "Could not create the ghost account" }, 400);
    }
    const newId = created.user.id;

    const { error: regErr } = await admin.rpc("register_ghost_account", {
      p_actor: user.id,
      p_user: newId,
      p_label: label,
      p_notes: body.notes?.trim() ?? "",
      p_login_email: email,
    });
    if (regErr) {
      // leave nothing behind (the profile goes with the auth user via FK cascade)
      await admin.auth.admin.deleteUser(newId);
      return json({ error: `Could not register the ghost: ${regErr.message}` }, 400);
    }
    return json({ user_id: newId, email, temp_password: generated ? password : null });
  }

  // everything below targets an existing ghost
  const targetId = body.user_id?.trim();
  if (!targetId || !UUID_RE.test(targetId)) return json({ error: "user_id is required" }, 400);
  const { data: ghost } = await admin
    .from("ghost_accounts").select("label").eq("profile_id", targetId).maybeSingle();
  if (!ghost) return json({ error: "That is not a ghost account" }, 404);

  if (body.action === "set_password") {
    if (body.password && (body.password.length < 8 || body.password.length > 72)) {
      return json({ error: "Password must be 8-72 characters" }, 400);
    }
    const generated = !body.password;
    const password = body.password || tempPassword();
    const { error } = await admin.auth.admin.updateUserById(targetId, { password });
    if (error) return json({ error: error.message }, 400);
    await audit("ghost.password_reset", ghost.label, "info");
    return json({ user_id: targetId, temp_password: generated ? password : null });
  }

  if (body.action === "set_active") {
    if (typeof body.active !== "boolean") return json({ error: "active must be true or false" }, 400);
    const { error } = await admin.auth.admin.updateUserById(targetId, {
      ban_duration: body.active ? "none" : BANNED,
    });
    if (error) return json({ error: error.message }, 400);
    await admin.from("ghost_accounts").update({ active: body.active }).eq("profile_id", targetId);
    await audit(body.active ? "ghost.enabled" : "ghost.disabled", ghost.label, "info");
    return json({ ok: true });
  }

  if (body.action === "delete") {
    const { error } = await admin.auth.admin.deleteUser(targetId);
    if (error) return json({ error: error.message }, 400);
    await audit("ghost.deleted", ghost.label);
    return json({ ok: true });
  }

  return json({ error: "action must be one of create, set_password, set_active, delete" }, 400);
});
