// What a caller may do in a LiveKit room. Pure rules, kept apart from index.ts (which imports Deno modules) so Node's test runner can check them.
// The WHO-may-publish decisions (host, seat holder, PK hosts, ghosts) are made in index.ts with the same helpers the Agora function uses;
// this only turns the decision into LiveKit's grant.

import type { VideoGrant } from "./livekit_jwt.ts";

/** LiveKit's TrackSource enum: UNKNOWN 0, CAMERA 1, MICROPHONE 2, SCREEN_SHARE 3, SCREEN_SHARE_AUDIO 4. */
export const TRACK_SOURCE_MICROPHONE = 2;

export function buildGrant(opts: {
  room: string;
  /** The caller may send sound / picture into the room (host, a seat holder, a PK host). */
  canPublish: boolean;
  /** A ghost / Super Admin watch: not listed to the others, can never publish. */
  hidden?: boolean;
  /** An audio room: a publisher may only send the microphone, never a camera. */
  audioOnly?: boolean;
}): VideoGrant {
  const publish = opts.canPublish && !opts.hidden;
  return {
    room: opts.room,
    roomJoin: true,
    canPublish: publish,
    canSubscribe: true,
    // chat, gifts and seats all go through Supabase, so nobody needs the room's data channel (one less thing to abuse)
    canPublishData: false,
    // TrackSource.MICROPHONE = 2 (a number: see VideoGrant.canPublishSources)
    ...(publish && opts.audioOnly ? { canPublishSources: [TRACK_SOURCE_MICROPHONE] } : {}),
    ...(opts.hidden ? { hidden: true } : {}),
  };
}
