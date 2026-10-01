// Sends a push notification (via FCM's HTTP v1 API) for a single row just
// inserted into public.notifications. Called ONLY by the notifications_push
// trigger (see supabase/migrations/20260929100000_push_notifications.sql)
// via pg_net — never by the client directly, which is why this is deployed
// with verify_jwt disabled and instead checks the shared X-Internal-Secret
// header against the PUSH_INTERNAL_SECRET stored in this project's Vault.
//
// Request body: { "profile_id": string, "kind": string, "body": string, "notification_id": string }
//
// Needs two secrets set on this function (`supabase secrets set ...`):
//   PUSH_INTERNAL_SECRET   — matches the value in vault.decrypted_secrets
//                            (name = 'push_internal_secret'); generated once
//                            by the migration, never sent to the client.
//   FCM_SERVICE_ACCOUNT_JSON — the full JSON key from Firebase Console →
//                            Project Settings → Service Accounts → Generate
//                            new private key. Its own project_id field is
//                            used directly, no separate FCM project id secret
//                            needed.
//
// A token FCM reports as unregistered/invalid is deleted from device_tokens
// so it stops being tried on every future notification.

import { createClient } from "npm:@supabase/supabase-js@2";
import { GoogleAuth } from "npm:google-auth-library@9";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PUSH_INTERNAL_SECRET = Deno.env.get("PUSH_INTERNAL_SECRET") ?? "";
const FCM_SERVICE_ACCOUNT_JSON = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON") ?? "";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function titleFor(kind: string): string {
  if (kind.startsWith("coins_")) return "SabaLive Wallet";
  switch (kind) {
    case "live":
      return "Live Now";
    case "message":
      return "New Message";
    case "follow":
      return "New Follower";
    default:
      return "SabaLive";
  }
}

let cachedAuth: GoogleAuth | null = null;
function fcmAuth(): GoogleAuth {
  if (!cachedAuth) {
    cachedAuth = new GoogleAuth({
      credentials: JSON.parse(FCM_SERVICE_ACCOUNT_JSON),
      scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
    });
  }
  return cachedAuth;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!PUSH_INTERNAL_SECRET || req.headers.get("X-Internal-Secret") !== PUSH_INTERNAL_SECRET) {
    return json({ error: "Unauthorized" }, 401);
  }
  if (!FCM_SERVICE_ACCOUNT_JSON) {
    // Not configured yet — swallow rather than fail the DB trigger's caller.
    return json({ skipped: "FCM_SERVICE_ACCOUNT_JSON not set" });
  }

  let payload: { profile_id?: string; kind?: string; body?: string; notification_id?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const { profile_id, kind, body } = payload;
  if (!profile_id || !kind || !body) {
    return json({ error: "profile_id, kind and body are required" }, 400);
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: tokens, error: tokensError } = await admin
    .from("device_tokens")
    .select("token")
    .eq("profile_id", profile_id);
  if (tokensError) {
    return json({ error: tokensError.message }, 500);
  }
  if (!tokens || tokens.length === 0) {
    return json({ sent: 0 });
  }

  const projectId = JSON.parse(FCM_SERVICE_ACCOUNT_JSON).project_id as string;
  const client = await fcmAuth().getClient();
  const { token: accessToken } = await client.getAccessToken();

  const staleTokens: string[] = [];
  const errors: string[] = [];
  let sent = 0;
  await Promise.all(
    tokens.map(async ({ token }) => {
      const res = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: titleFor(kind), body },
              data: { kind },
            },
          }),
        },
      );
      if (res.ok) {
        sent++;
        return;
      }
      const errBody = await res.text();
      if (res.status === 404 || errBody.includes("UNREGISTERED") || errBody.includes("NOT_FOUND")) {
        staleTokens.push(token);
      } else {
        // Anything other than "this token is dead" (bad credentials,
        // rate limiting, a malformed request) — worth surfacing since it
        // won't self-heal the way a stale token does.
        errors.push(`${res.status}: ${errBody}`);
      }
    }),
  );

  if (staleTokens.length > 0) {
    await admin.from("device_tokens").delete().eq("profile_id", profile_id).in("token", staleTokens);
  }

  return json({ sent, staleRemoved: staleTokens.length, errors });
});
