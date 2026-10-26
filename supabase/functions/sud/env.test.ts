import test from "node:test";
import assert from "node:assert/strict";
import { envValue } from "./env.ts";

test("the exact upper-case name is used", () => {
  assert.equal(envValue({ SUD_APP_KEY: "k1" }, "SUD_APP_KEY"), "k1");
});

test("the same name with other capitals is found (the dashboard keeps what was typed)", () => {
  assert.equal(envValue({ SUD_App_Key: "k2" }, "SUD_APP_KEY"), "k2");
  assert.equal(envValue({ sud_app_secret: "s" }, "SUD_APP_SECRET"), "s");
  assert.equal(envValue({ SUD_App_Id: "123" }, "SUD_APP_ID"), "123");
});

test("the exact upper-case spelling wins when both exist", () => {
  assert.equal(envValue({ SUD_App_Key: "mixed", SUD_APP_KEY: "upper" }, "SUD_APP_KEY"), "upper");
});

test("an empty exact value does not hide a mixed-case one, and a missing or empty one is an empty string", () => {
  assert.equal(envValue({ SUD_APP_KEY: "", SUD_App_Key: "mixed" }, "SUD_APP_KEY"), "mixed");
  assert.equal(envValue({}, "SUD_APP_KEY"), "");
  assert.equal(envValue({ SUD_APP_KEY: "" }, "SUD_APP_KEY"), "");
  assert.equal(envValue({ SUD_APP_KEY: undefined }, "SUD_APP_KEY"), "");
});

test("a different name never matches, even when it shares a prefix", () => {
  assert.equal(envValue({ SUD_APP_KEY_OLD: "x", SUD_APP_KEYS: "y" }, "SUD_APP_KEY"), "");
});
