import assert from "node:assert/strict";
import { chdir } from "node:process";

import { parseStructuredTyped, parseTyped } from "./typed.mjs";

chdir("tests/fixtures/nested/deeper");
const configPath = "../../../codegen/.cli-flags.toml";

const parsed = parseTyped(
  ["app", "--port=8181", "--ratio=1.25", "--debug=1", "--items=[1,2,3]", '--labels={"tier":2}'],
  { configPath },
);
assert.equal(parsed.PORT, 8181);
assert.equal(typeof parsed.PORT, "number");
assert.equal(parsed.RATIO, 1.25);
assert.equal(typeof parsed.DEBUG, "boolean");
assert.equal(parsed.DEBUG, true);
assert.deepEqual(parsed.ITEMS, [1, 2, 3]);
assert.deepEqual(parsed.LABELS, { tier: 2 });
assert.equal(parsed.isHelpMenu, false);
assert.equal(Object.keys(parsed).includes("isHelpMenu"), false);
assert.equal(Object.keys(parsed).includes("printTable"), false);

const structured = parseStructuredTyped(
  ["app", "--port=8282", "--debug=0", "--items=[4,5]"],
  { configPath },
);
assert.equal(structured.flags.PORT, 8282);
assert.equal(typeof structured.flags.PORT, "number");
assert.equal(structured.flags.DEBUG, false);
assert.deepEqual(structured.flags.ITEMS, [4, 5]);
assert.equal(structured.providedFlags.PORT, "8282");
assert.equal(structured.providedFlags.DEBUG, "false");
assert.equal(structured.providedFlags.ITEMS, "[4,5]");
