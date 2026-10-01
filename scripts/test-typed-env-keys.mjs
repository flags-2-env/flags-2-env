#!/usr/bin/env node

import assert from "node:assert/strict";
import { parseContract, renderAll } from "./generate-typed-env-keys.mjs";

const contract = parseContract(`
[identity]
type_name = "DemoEnv"

[parse]
command_env = "DEMO_COMMAND"
unknown_options_env = "DEMO_UNKNOWN"

[flags.port]
env = "PORT"
type = "integer"

[flags.rust-log]
env = "RUST_LOG"
type = "string"

[commands.remote]
env = "REMOTE_SELECTED"

[commands.remote.flags.url]
env = "REMOTE_URL"
type = "string"

[env]
ignore = ["DATABASE_URL"]
`);

assert.equal(contract.typeName, "DemoEnv");
assert.deepEqual(contract.keys, [
  "DEMO_COMMAND",
  "DEMO_UNKNOWN",
  "PORT",
  "REMOTE_SELECTED",
  "REMOTE_URL",
  "RUST_LOG",
]);
assert.ok(!contract.keys.includes("DATABASE_URL"), "env.ignore entries are not parser-emitted public keys");

const generated = renderAll(contract);

assert.match(generated["env_keys.ts"], /export type DemoEnvKey/);
assert.match(generated["env_keys.ts"], /Partial<Record<DemoEnvKey, string>>/);
assert.match(generated["env_keys.ts"], /defineDemoEnvMap/);
assert.doesNotMatch(generated["env_keys.ts"], /Record<string, string>/);

assert.match(generated["env_keys.rs"], /pub enum DemoEnvKey/);
assert.match(generated["env_keys.rs"], /BTreeMap<DemoEnvKey, String>/);
assert.doesNotMatch(generated["env_keys.rs"], /BTreeMap<String, String>/);

assert.match(generated["env_keys.gleam"], /pub opaque type DemoEnvKey/);
assert.match(generated["env_keys.gleam"], /Dict\(DemoEnvKey, String\)/);
assert.match(generated["env_keys.gleam"], /pub fn env_port\(\) -> DemoEnvKey/);

assert.match(generated["env_keys.dart"], /final class DemoEnvKey/);
assert.match(generated["env_keys.dart"], /Map<DemoEnvKey, String>/);
assert.match(generated["env_keys.dart"], /static const envPort/);
assert.doesNotMatch(generated["env_keys.dart"], /Map<String, String>/);

const empty = renderAll(parseContract(`[identity]\ntype_name = "EmptyEnv"\n`));
assert.match(empty["env_keys.ts"], /export type EmptyEnvKey/);
assert.match(empty["env_keys.rs"], /pub enum EmptyEnvKey \{/);
assert.match(empty["env_keys.gleam"], /pub opaque type EmptyEnvKey/);
assert.match(empty["env_keys.dart"], /final class EmptyEnvKey/);

assert.throws(
  () => parseContract(`[flags.bad]\nenv = "BAD-KEY"\n`),
  /invalid environment key/,
);

process.stdout.write("typed env-key generator tests passed\n");
