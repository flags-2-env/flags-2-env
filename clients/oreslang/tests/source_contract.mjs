import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = await readFile(new URL("../src/flags2env.ores", import.meta.url), "utf8");
const scalar = await readFile(new URL("./abi-status-scalar.ores", import.meta.url), "utf8");
const header = await readFile(new URL("../native/flags2env_ores_bridge.h", import.meta.url), "utf8");
const pkg = await readFile(new URL("../.ores.pkg.toml", import.meta.url), "utf8");
const backendContract = JSON.parse(
  await readFile(new URL("../../../contracts/oreslang-client-backends.v1.json", import.meta.url), "utf8")
);

for (const token of [
  "status_ok",
  "status_name",
  "host_parse_blocking_with",
  "host_coerce_blocking_with",
  "HostReply",
]) {
  assert.match(source, new RegExp("\\b" + token + "\\b"));
}
assert.doesNotMatch(source, /\bnull\b/);
assert.doesNotMatch(source, /\basync\b/);
assert.doesNotMatch(source, /(?:^|\s)[*&][A-Za-z_]/m);
assert.doesNotMatch(source, /\bpub\s+fnc\s+parse_with\b/);
assert.doesNotMatch(source, /\bpub\s+fnc\s+coerce_with\b/);
assert.match(scalar, /pub fnc main\(\): int/);
assert.match(scalar, /return[\s\S]*- 1192;/);

for (const [name, value] of [
  ["F2E_ORES_OK", 0],
  ["F2E_ORES_INVALID_INPUT", 1],
  ["F2E_ORES_NATIVE_FAILURE", 2],
  ["F2E_ORES_INPUT_TOO_LARGE", 3],
  ["F2E_ORES_OUTPUT_TOO_LARGE", 4],
  ["F2E_ORES_RELEASED", 5],
]) {
  assert.match(header, new RegExp(name + "\\s*=\\s*" + value + "\\b"));
}

assert.deepEqual(
  backendContract.required_backends,
  ["java", "llvm", "wasm", "cranelift", "dotnet"]
);
assert.equal(backendContract.policy.unsupported_is_pass, false);
assert.equal(backendContract.policy.compile_only_is_runtime_pass, false);
assert.equal(backendContract.policy.zero_step_ci_is_pass, false);
assert.equal(backendContract.policy.blocking_native_call_on_actor_carrier, false);
assert.equal(backendContract.evidence, "not-attested");
assert.match(pkg, /\bname\s*=\s*"flags2env"/);
assert.match(pkg, /roots\s*=\s*\["src"\]/);

console.log("ORES-FLAGS2ENV-SOURCE-CONTRACT-PASS|cases=26");
