// Mints a short-lived Agora RTC token for a channel.
//
// The platform-level JWT check (this function is deployed WITHOUT
// --no-verify-jwt) only proves the caller holds a validly-signed key for
// this project — the public anon/publishable key satisfies that too, and it
// ships inside the app binary. So we additionally resolve the caller to a
// real signed-in Supabase user via auth.getUser() and reject anonymous
// callers outright. The App Certificate never leaves this server; it is
// read from the AGORA_APP_CERTIFICATE secret and is never sent to the client.
//
// Request body: { "channelName": string, "role"?: "publisher" | "subscriber" }
// Response body: { "token": string, "appId": string, "channelName": string, "uid": 0, "expiresIn": number }
//
// uid is always 0 — the client's Agora SDK is left to assign the real
// numeric uid on join, which is the standard pattern when the app's own
// user ids are UUIDs rather than Agora's native 32-bit uid.

import { createClient } from "npm:@supabase/supabase-js@2";
import { RtcRole, RtcTokenBuilder } from "npm:agora-token@2.0.5";

const APP_ID = Deno.env.get("AGORA_APP_ID") ?? "";
const APP_CERTIFICATE = Deno.env.get("AGORA_APP_CERTIFICATE") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const TOKEN_TTL_SECONDS = 3600;

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
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!APP_ID || !APP_CERTIFICATE) {
    return json({ error: "Agora credentials are not configured on the server" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return json({ error: "You must be signed in to request a streaming token" }, 401);
  }

  let body: { channelName?: string; role?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const channelName = body.channelName?.trim();
  if (!channelName) {
    return json({ error: "channelName is required" }, 400);
  }

  const role = body.role === "subscriber" ? RtcRole.SUBSCRIBER : RtcRole.PUBLISHER;

  // Publisher tokens let the holder actually broadcast into the channel.
  // A "pk-<battleId>" channel is the shared arena two matched PK hosts
  // rejoin into once their battle goes live — only those two hosts may
  // publish into it. Everything else falls through to the live_streams
  // check below (e.g. a 1:1 call's "call-<uuid>" channel matches neither
  // and mints unchanged, exactly as before).
  if (role === RtcRole.PUBLISHER && channelName.startsWith("pk-")) {
    const battleId = channelName.slice(3);
    const { data: battle } = await userClient
      .from("pk_battles")
      .select("host_a_id, host_b_id, status")
      .eq("id", battleId)
      .maybeSingle();
    if (!battle || battle.status !== "live" ||
        (battle.host_a_id !== user.id && battle.host_b_id !== user.id)) {
      return json({ error: "Not authorized to publish to this PK battle" }, 403);
    }
  } else if (role === RtcRole.PUBLISHER) {
    // For a channel that's a real live_streams row, only that stream's host
    // or someone currently holding a claimed seat on it may publish — every
    // other authenticated user used to get a publisher token for any channel
    // name with no check at all. A channelName that ISN'T a live_streams id
    // simply won't match any row here and falls through unchanged.
    const { data: stream } = await userClient
      .from("live_streams")
      .select("host_id")
      .eq("id", channelName)
      .maybeSingle();
    if (stream) {
      const isHost = stream.host_id === user.id;
      let isSeated = false;
      if (!isHost) {
        const { data: seat } = await userClient
          .from("live_stream_seats")
          .select("seat_number")
          .eq("live_stream_id", channelName)
          .eq("occupant_id", user.id)
          .maybeSingle();
        isSeated = !!seat;
      }
      if (!isHost && !isSeated) {
        return json({ error: "Not authorized to publish to this stream" }, 403);
      }
    }
  }

  const token = RtcTokenBuilder.buildTokenWithUid(
    APP_ID,
    APP_CERTIFICATE,
    channelName,
    0,
    role,
    TOKEN_TTL_SECONDS,
    TOKEN_TTL_SECONDS,
  );

  return json({
    token,
    appId: APP_ID,
    channelName,
    uid: 0,
    expiresIn: TOKEN_TTL_SECONDS,
  });
});
