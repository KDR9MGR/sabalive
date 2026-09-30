// Creates a brand-new auth user and grants them a staff_roles row, so the
// sabaliveadmin panel can add an admin / agency staffer who has never
// signed in. The panel only holds the anon key and cannot call
// auth.admin.* — this runs with the service-role key, which never leaves
// the server.
//
// The platform JWT check proves the caller holds a valid project key (the
// anon key satisfies that), so we additionally resolve the caller to a
// real user. Who may create WHICH role is decided in SQL, not here:
//   super_admin   -> any role
//   global_admin  -> country_admin, sub_admin, agency_manager
//   country_admin -> sub_admin (owned by them), agency_manager (in their tree)
//   sub_admin     -> agency_manager (for an agency they own)
// check_staff_creation() validates before the auth user is made, and
// create_staff_account() (service_role only) re-checks and inserts the row.
//
// Request body:
//   { "email": string,
//     "role": "admin" | "super_admin" | "global_admin" | "country_admin" | "agency_manager" | "sub_admin",
//     "agency_id"?: uuid,          // required for agency_manager; optional for sub_admin
//     "country_admin_id"?: uuid,   // sub_admin only: the country_admin that will own them
//     "password"?: string,         // omitted -> a strong temp password is generated
//     "full_name"?: string,
//     "username"?: string,         // omitted -> falls back to user_<id8>
//     "phone"?: string,
//     "location"?: string,        // "Country" in the admin panel form; defaults to India
//     "payment_pin"?: string }     // 4-6 digits; stored as a bcrypt hash, never plaintext
//
// Response: { "user_id": uuid, "email": string, "role": string,
//             "temp_password": string | null }   // set only when we generated one

import { createClient } from "npm:@supabase/supabase-js@2";
import bcrypt from "npm:bcryptjs@2.4.3";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const PLATFORM_ROLES = ["admin", "super_admin", "global_admin", "country_admin"];
const AGENCY_ROLES = ["agency_manager", "sub_admin"];
const ALL_ROLES = [...PLATFORM_ROLES, ...AGENCY_ROLES];
// roles that may create accounts at all — the per-role / per-scope rules live in SQL
const CREATOR_ROLES = ["super_admin", "global_admin", "country_admin", "sub_admin"];

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

  // 2. caller must be staff at a level that can create accounts
  //    (which roles, and inside which scope, is checked in SQL below)
  const { data: callerRole } = await admin
    .from("staff_roles").select("role").eq("user_id", user.id).maybeSingle();
  if (!callerRole || !CREATOR_ROLES.includes(callerRole.role)) {
    return json({ error: "Your role cannot create accounts" }, 403);
  }

  // 3. validate the request
  let body: {
    email?: string; role?: string; agency_id?: string; country_admin_id?: string;
    password?: string; full_name?: string;
    username?: string; phone?: string; location?: string; payment_pin?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const email = body.email?.trim().toLowerCase();
  const role = body.role?.trim();
  const agencyId = body.agency_id?.trim() || null;
  const countryAdminId = body.country_admin_id?.trim() || null;
  const username = body.username?.trim() || undefined;
  const phone = body.phone?.trim() || undefined;
  const location = body.location?.trim() || undefined;
  const paymentPin = body.payment_pin?.trim() || undefined;

  if (!email || !email.includes("@")) return json({ error: "A valid email is required" }, 400);
  if (!role || !ALL_ROLES.includes(role)) return json({ error: `role must be one of ${ALL_ROLES.join(", ")}` }, 400);
  if (role === "agency_manager" && !agencyId) return json({ error: "agency_manager requires an agency_id" }, 400);
  if (PLATFORM_ROLES.includes(role) && agencyId) return json({ error: `${role} must not have an agency_id` }, 400);
  if (countryAdminId && role !== "sub_admin") {
    return json({ error: "country_admin_id is only valid for a sub_admin" }, 400);
  }
  if (username && !/^[a-zA-Z0-9_]{3,30}$/.test(username)) {
    return json({ error: "Username must be 3-30 characters: letters, numbers, underscore" }, 400);
  }
  if (paymentPin && !/^\d{4,6}$/.test(paymentPin)) {
    return json({ error: "Payment PIN must be 4-6 digits" }, 400);
  }

  // 3b. may THIS caller create THIS role in THIS scope? (rules live in SQL)
  const { error: checkErr } = await admin.rpc("check_staff_creation", {
    p_actor: user.id,
    p_role: role,
    p_agency_id: agencyId,
    p_country_admin_id: countryAdminId,
  });
  if (checkErr) return json({ error: checkErr.message }, 403);

  // 4. create the auth user (email pre-confirmed so they can sign in immediately)
  const generated = !body.password;
  const password = body.password || tempPassword();

  const metadata: Record<string, string> = {};
  if (body.full_name) metadata.name = body.full_name;
  if (username) metadata.username = username;
  if (phone) metadata.phone = phone;
  if (location) metadata.location = location;

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    // the on_auth_user_created trigger reads name/username/phone/location
    // from here to seed the profiles row.
    user_metadata: Object.keys(metadata).length ? metadata : undefined,
  });
  if (createErr || !created?.user) {
    return json({ error: createErr?.message || "Could not create the user" }, 400);
  }
  const newId = created.user.id;

  // 5. grant the role (the profiles row already exists via the
  //    on_auth_user_created trigger)
  const payment_pin_hash = paymentPin ? bcrypt.hashSync(paymentPin, 10) : null;
  const { error: roleErr } = await admin.rpc("create_staff_account", {
    p_actor: user.id,
    p_user_id: newId,
    p_role: role,
    p_agency_id: agencyId,
    p_country_admin_id: countryAdminId,
    p_payment_pin_hash: payment_pin_hash,
  });
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
