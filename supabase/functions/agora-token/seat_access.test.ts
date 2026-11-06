import test from "node:test";
import assert from "node:assert/strict";
import { CP_SEAT_NUMBERS, FULL_TTL_SECONDS, GUEST_PUBLISHER_TTL_SECONDS, cpSeatGivesMic, isCpSeatNumber, publisherTtlSeconds, seatGivesMic, type StreamRow } from "./seat_access.ts";

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

test("couple seats are 24 and 25 and nothing else", () => {
  assert.deepEqual([...CP_SEAT_NUMBERS], [24, 25]);
  assert.equal(isCpSeatNumber(24), true);
  assert.equal(isCpSeatNumber(25), true);
  for (const n of [1, 16, 23, 26, 0, null, undefined]) assert.equal(isCpSeatNumber(n as number | null | undefined), false);
});

test("a couple seat gives the mic only in a live audio room that has CP seats switched on", () => {
  const on = { mode: "audio", status: "live", cp_seats: true };
  assert.equal(cpSeatGivesMic(24, on), true);
  assert.equal(cpSeatGivesMic(25, on), true);
  assert.equal(cpSeatGivesMic(24, { ...on, cp_seats: false }), false, "switched off");
  assert.equal(cpSeatGivesMic(24, { ...on, cp_seats: null }), false, "unknown is off");
  assert.equal(cpSeatGivesMic(24, { mode: "audio", status: "live" }), false, "a server without the column");
  assert.equal(cpSeatGivesMic(24, { ...on, status: "ended" }), false);
  assert.equal(cpSeatGivesMic(24, { ...on, mode: "video" }), false);
  assert.equal(cpSeatGivesMic(24, { ...on, mode: "pk" }), false);
  assert.equal(cpSeatGivesMic(3, on), false, "an ordinary seat is decided by seatGivesMic, not here");
  assert.equal(cpSeatGivesMic(null, on), false);
});

test("the ordinary rule still says no to a couple seat: only the CP rule can open it", () => {
  assert.equal(seatGivesMic(24, { ...audio, seat_count: 16 }), false);
  assert.equal(seatGivesMic(25, { ...audio, seat_count: 16 }), false);
});
