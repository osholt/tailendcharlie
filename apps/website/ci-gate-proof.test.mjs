import assert from "node:assert/strict";
import test from "node:test";

test("CI rejects a deliberately failing website test", () => {
  assert.fail("deliberate failure used to prove the Website CI gate");
});
