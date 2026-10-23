import test from "node:test";
import assert from "node:assert/strict";
import { FULL_TTL_SECONDS, GUEST_PUBLISHER_TTL_SECONDS, publisherTtlSeconds, seatGivesMic, type StreamRow } from "./seat_access.ts";

const audio: StreamRow = { host_id: "h", mode: "audio", status: "live", seat_count: 4 };

test("a seat inside the room's range gives the mic", () => {
  for (const n of [1, 2, 3, 4]) assert.equal(seatGivesMic(n, audio), true);
});

test("an audio seat outside the range gives nothing: invisible to the host, so it must not talk", () => {
  for (const n of [0, 5, 6, 99, -1]) assert.equal(seatGivesMic(n, audio), false);
});

test("lowering the seat count takes the mic from the seats beyond it", () => {
  assert.equal(seatGivesMic(6, { ...audio, seat_count: 8 }), true);
  assert.equal(seatGivesMic(6, { ...audio, seat_count: 4 }), false);
});

test("no seat, or a nonsense seat, gives nothing", () => {
  assert.equal(seatGivesMic(null, audio), false);
  assert.equal(seatGivesMic(undefined, audio), false);
  assert.equal(seatGivesMic(2.5, audio), false);
});

test("a finished live gives nothing to anyone but the host (who is checked separately)", () => {
  assert.equal(seatGivesMic(1, { ...audio, status: "ended" }), false);
});

test("video and PK rooms keep their own seat numbering: any real seat row counts, while the live is on", () => {
  assert.equal(seatGivesMic(7, { ...audio, mode: "pk", seat_count: 5 }), true);
  assert.equal(seatGivesMic(3, { ...audio, mode: "video" }), true);
  assert.equal(seatGivesMic(3, { ...audio, mode: "video", status: "ended" }), false);
});

test("a guest's speaking token is short, a host's keeps the hour", () => {
  assert.equal(publisherTtlSeconds(false), GUEST_PUBLISHER_TTL_SECONDS);
  assert.equal(publisherTtlSeconds(true), FULL_TTL_SECONDS);
  assert.ok(GUEST_PUBLISHER_TTL_SECONDS < FULL_TTL_SECONDS && GUEST_PUBLISHER_TTL_SECONDS >= 300);
});
