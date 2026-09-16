// Creates a brand-new auth user and grants them a staff_roles row, so the
// sabaliveadmin panel can add an admin / agency staffer who has never
// signed in. The panel only holds the anon key and cannot call
// auth.admin.* — this runs with the service-role key, which never leaves
// the server.
//
// The platform JWT check proves the caller holds a valid project key (the
// anon key satisfies that), so we additionally resolve the caller to a
// real user and require them to be a super_admin.
//
// Request body:
//   { "email": string,
//     "role": "admin" | "super_admin" | "agency_manager" | "sub_admin",
//     "agency_id"?: uuid,          // required for agency_manager / sub_admin
//     "password"?: string,         // omitted -> a strong temp password is generated
//     "full_name"?: string }
//
// Response: { "user_id": uuid, "email": string, "role": string,
//             "temp_password": string | null }   // set only when we generated one

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const PLATFORM_ROLES = ["admin", "super_admin"];
const AGENCY_ROLES = ["agency_manager", "sub_admin"];
const ALL_ROLES = [...PLATFORM_ROLES, ...AGENCY_ROLES];

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

function tempPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(18));
  return btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, "").slice(0, 20) + "aA1!";
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

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // 2. caller must be a super_admin
  const { data: callerRole } = await admin
    .from("staff_roles").select("role").eq("user_id", user.id).maybeSingle();
  if (callerRole?.role !== "super_admin") {
    return json({ error: "Only a Super Admin can invite staff" }, 403);
  }

  // 3. validate the request
  let body: {
    email?: string; role?: string; agency_id?: string;
    password?: string; full_name?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const email = body.email?.trim().toLowerCase();
  const role = body.role?.trim();
  const agencyId = body.agency_id?.trim() || null;

  if (!email || !email.includes("@")) return json({ error: "A valid email is required" }, 400);
  if (!role || !ALL_ROLES.includes(role)) return json({ error: `role must be one of ${ALL_ROLES.join(", ")}` }, 400);
  if (AGENCY_ROLES.includes(role) && !agencyId) return json({ error: `${role} requires an agency_id` }, 400);
  if (PLATFORM_ROLES.includes(role) && agencyId) return json({ error: `${role} must not have an agency_id` }, 400);

  // 4. create the auth user (email pre-confirmed so they can sign in immediately)
  const generated = !body.password;
  const password = body.password || tempPassword();

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    // the on_auth_user_created trigger reads `name` and (optionally)
    // `username` from here to seed the profiles row; we leave username to
    // its unique user_<id> fallback to avoid collisions between invites.
    user_metadata: body.full_name ? { name: body.full_name } : undefined,
  });
  if (createErr || !created?.user) {
    return json({ error: createErr?.message || "Could not create the user" }, 400);
  }
  const newId = created.user.id;

  // 5. grant the role (the profiles row already exists via the
  //    on_auth_user_created trigger)
  const { error: roleErr } = await admin.from("staff_roles")
    .insert({ user_id: newId, role, agency_id: agencyId });
  if (roleErr) {
    // roll back the auth user (and its profiles row, via FK cascade) so a
    // failed invite leaves nothing behind
    await admin.auth.admin.deleteUser(newId);
    return json({ error: `Could not grant the role: ${roleErr.message}` }, 400);
  }

  await admin.from("audit_logs").insert({
    actor_id: user.id,
    action: "staff.invited",
    target: `${email} -> ${role}`,
    severity: "warning",
  });

  return json({
    user_id: newId,
    email,
    role,
    temp_password: generated ? password : null,
  });
});
