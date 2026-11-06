// Mints a short-lived LiveKit access token for a room, for a hosted LiveKit server (LiveCore). STAGING EXPERIMENT (2026-11-05): a new function next to
// `agora-token`, which is untouched; nothing in the app calls this one yet. See docs/STREAMING_SERVER_SWAP.md.
//
// It answers the same questions `agora-token` does, with the same helpers, so the two providers can never disagree about who may speak:
//   - the caller must be a signed-in Supabase user (the anon key alone is not enough);
//   - bans, a banned device, a host who removed / blocked the caller: live_access_denied_reason (SQL), exactly as for Agora;
//   - publishing into a live: only its host or someone on a seat that really gives the mic (seat_access.ts); a guest's token is short (600 s);
//   - publishing into a PK arena "pk-<battleId>": only who battle_access.ts allows;
//   - ghost / Super Admin watching: view-only AND hidden, so nobody sees them in the room (the grant's `hidden` flag).
// The identity in the token is the Supabase user id, so "who is talking" maps straight to a seat's occupant (no agora_uid table needed).
// The API secret is read from the LIVEKIT_API_SECRET secret and never sent to the client.
//
// Request body: { "channelName": string, "role"?: "publisher" | "subscriber", "ghost"?: boolean }   (same shape as agora-token)
// Response body: { "token": string, "url": string, "room": string, "identity": string, "expiresIn": number }

import { createClient } from "npm:@supabase/supabase-js@2";
import { mayPublishToBattle } from "../agora-token/battle_access.ts";
import { cpSeatGivesMic, isCpSeatNumber, publisherTtlSeconds, seatGivesMic } from "../agora-token/seat_access.ts";
import { buildGrant } from "./grants.ts";
import { signLiveKitToken } from "./livekit_jwt.ts";

const LIVEKIT_URL = Deno.env.get("LIVEKIT_URL") ?? "";
const API_KEY = Deno.env.get("LIVEKIT_API_KEY") ?? "";
const API_SECRET = Deno.env.get("LIVEKIT_API_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const TOKEN_TTL_SECONDS = 3600;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-device-id",
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!LIVEKIT_URL || !API_KEY || !API_SECRET) {
    return json({ error: "LiveKit credentials are not configured on the server" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const deviceId = req.headers.get("x-device-id") ?? "";
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: {
      headers: {
        Authorization: authHeader,
        ...(deviceId ? { "x-device-id": deviceId } : {}),
      },
    },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return json({ error: "You must be signed in to request a streaming token" }, 401);
  }

  let body: { channelName?: string; role?: string; ghost?: boolean };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const channelName = body.channelName?.trim();
  if (!channelName) return json({ error: "channelName is required" }, 400);

  // Ghost viewing (see ghost_watch_mode): an active ghost account in the app, or a Super Admin / Master asking for ghost:true. Always view-only.
  const { data: ghostMode } = await userClient.rpc("ghost_watch_mode");
  if (body.ghost === true && !ghostMode) {
    return json({ error: "You are not allowed to watch lives invisibly" }, 403);
  }
  const isGhostViewer = !!ghostMode && (ghostMode === "ghost" || body.ghost === true);
  if (isGhostViewer && body.role !== "subscriber") {
    return json({ error: "Ghost viewers can only watch" }, 403);
  }

  const wantsPublish = body.role !== "subscriber";
  let ttl = TOKEN_TTL_SECONDS;
  let audioOnly = false;

  // 1:1 call rooms ("call-<uuid>") are not lives; everything else is, and a room that is a live_streams id also gets the per-room checks.
  if (!channelName.startsWith("call-") && !isGhostViewer) {
    const { data: denied, error: deniedError } = await userClient.rpc(
      "live_access_denied_reason",
      { p_user: user.id, p_stream: UUID_RE.test(channelName) ? channelName : null },
    );
    if (deniedError) return json({ error: "Could not check live access" }, 500);
    if (Array.isArray(denied) && denied.length > 0) {
      return json({ error: denied[0].message, code: denied[0].code }, 403);
    }
  }

  if (wantsPublish && channelName.startsWith("pk-")) {
    const battleId = channelName.slice(3);
    const { data: battle } = await userClient
      .from("pk_battles")
      .select("host_a_id, host_b_id, status, stream_a_id, stream_b_id, source")
      .eq("id", battleId)
      .maybeSingle();
    let seatedStreamIds: string[] = [];
    if (battle && battle.status === "live" && battle.source != null &&
        battle.host_a_id !== user.id && battle.host_b_id !== user.id) {
      const { data: seats } = await userClient
        .from("live_stream_seats")
        .select("live_stream_id")
        .in("live_stream_id", [battle.stream_a_id, battle.stream_b_id])
        .eq("occupant_id", user.id);
      seatedStreamIds = (seats ?? []).map((r: { live_stream_id: string }) => r.live_stream_id);
    }
    if (!mayPublishToBattle(battle, user.id, seatedStreamIds)) {
      return json({ error: "Not authorized to publish to this PK battle" }, 403);
    }
  } else if (wantsPublish) {
    const { data: stream } = await userClient
      .from("live_streams")
      .select("host_id, mode, status, seat_count")
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
        isSeated = seatGivesMic(seat?.seat_number, stream);
        // a couple (CP) seat sits above the room's seat count, so the rule above never opens it: a room that has CP seats switched on does. A separate read, so
        // everything above is exactly what it was and a server without the column just answers "no" here
        if (!isSeated && isCpSeatNumber(seat?.seat_number)) {
          const { data: cp } = await userClient.from("live_streams").select("cp_seats").eq("id", channelName).maybeSingle();
          isSeated = cpSeatGivesMic(seat?.seat_number, { ...stream, cp_seats: cp?.cp_seats === true });
        }
      }
      if (!isHost && !isSeated) {
        return json({ error: "Not authorized to publish to this stream" }, 403);
      }
      ttl = publisherTtlSeconds(isHost);
      audioOnly = stream.mode === "audio";
    }
  }

  const token = await signLiveKitToken({
    apiKey: API_KEY,
    apiSecret: API_SECRET,
    identity: user.id,
    ttlSeconds: ttl,
    grant: buildGrant({ room: channelName, canPublish: wantsPublish && !isGhostViewer, hidden: isGhostViewer, audioOnly }),
  });

  return json({ token, url: LIVEKIT_URL, room: channelName, identity: user.id, expiresIn: ttl });
});
