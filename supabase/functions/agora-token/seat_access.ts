// Who counts as "seated" for a PUBLISHER token on a live_streams channel, and how long that token lives. Kept apart from index.ts (which
// imports Deno modules) so Node's test runner can check the rules: scripts/test_functions.sh.

export type StreamRow = {
  host_id: string;
  mode: string;
  status: string;
  seat_count: number;
};

/** A guest's speaking token only lasts this long (a host's keeps the full hour). The app renews it before it ends, and a renewal is refused
 *  the moment the seat is gone, so a removed guest loses the microphone within this window instead of up to an hour. */
export const GUEST_PUBLISHER_TTL_SECONDS = 600;
export const FULL_TTL_SECONDS = 3600;

/**
 * Whether a seat row really gives the right to speak:
 *  - the live must still be on;
 *  - in an AUDIO room the seat must be one of the room's visible seats (1..seat_count). A row outside that range cannot be seen or removed by
 *    the host, yet used to be enough to get a speaking token (host lowers the seat count, or a client writes a seat number that does not exist).
 *  Other modes (video, PK) keep their own seat numbering, so only the live check applies there; the database lets only the seat functions
 *  write seat rows (migration 20261023120000), so a row that exists is a real one.
 */
export function seatGivesMic(seatNumber: number | null | undefined, stream: StreamRow): boolean {
  if (seatNumber == null || !Number.isInteger(seatNumber)) return false;
  if (stream.status !== "live") return false;
  if (stream.mode === "audio") return seatNumber >= 1 && seatNumber <= stream.seat_count;
  return true;
}

export function publisherTtlSeconds(isHost: boolean): number {
  return isHost ? FULL_TTL_SECONDS : GUEST_PUBLISHER_TTL_SECONDS;
}
