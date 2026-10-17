import test from "node:test";
import assert from "node:assert/strict";
import { mayPublishToBattle, type BattleRow } from "./battle_access.ts";

const layer: BattleRow = { host_a_id: "ha", host_b_id: "hb", status: "live", stream_a_id: "sa", stream_b_id: "sb", source: "invite" };
const legacy: BattleRow = { ...layer, source: null };

test("the two hosts may publish in a live battle, layer or legacy", () => {
  assert.equal(mayPublishToBattle(layer, "ha", []), true);
  assert.equal(mayPublishToBattle(layer, "hb", []), true);
  assert.equal(mayPublishToBattle(legacy, "ha", []), true);
});

test("a guest on a seat of either room may publish in a layer battle", () => {
  assert.equal(mayPublishToBattle(layer, "guest", ["sa"]), true);
  assert.equal(mayPublishToBattle(layer, "guest", ["sb"]), true);
  assert.equal(mayPublishToBattle({ ...layer, source: "random" }, "guest", ["sb"]), true);
});

test("a legacy battle keeps the old rule: seat guests may not publish", () => {
  assert.equal(mayPublishToBattle(legacy, "guest", ["sa", "sb"]), false);
});

test("a listener, a guest of some other live, a missing or a finished battle may not", () => {
  assert.equal(mayPublishToBattle(layer, "viewer", []), false);
  assert.equal(mayPublishToBattle(layer, "guest", ["somewhere-else"]), false);
  assert.equal(mayPublishToBattle(null, "ha", ["sa"]), false);
  for (const status of ["invited", "accepted", "finished", "cancelled"]) {
    assert.equal(mayPublishToBattle({ ...layer, status }, "ha", ["sa"]), false, status);
  }
});
