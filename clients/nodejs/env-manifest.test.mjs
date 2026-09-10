import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  auditCliCoverage,
  checkRepositoryEnvManifest,
  discoverEnvManifest,
  parseEnvDeclarations,
  renderManifestEnv,
  syncRepositoryEnvManifest,
  syncCliEnvIndex,
} from "./env-manifest.mjs";

function dir() {
  return mkdtempSync(join(tmpdir(), "f2e-env-manifest-"));
}

function write(root, path, content) {
  const full = join(root, path);
  const parent = full.slice(0, full.lastIndexOf("/"));
  if (parent) mkdirSync(parent, { recursive: true });
  writeFileSync(full, content);
}

const base = `version = 1

[[env]]
name = "port"
key = "PORT"
kind = "integer"
required = false
secret = false
exposure = "argv-and-env"
description = "HTTP listener port."
overrides = ["server.port"]
environments = ["dev", "prod"]
default = 8080

[[env]]
name = "database_url"
key = "DATABASE_URL"
kind = "url"
required = true
secret = true
exposure = "env-only"
description = "Database credential URI."
overrides = ["server.database_url"]
environments = ["dev", "prod"]
`;

test("parses canonical [[env]] blocks without interpreting unrelated TOML", () => {
  const parsed = parseEnvDeclarations(`[server]\nport = 1\n${base}`, ".sample.toml");
  assert.equal(parsed.length, 2);
  assert.equal(parsed[0].key, "PORT");
  assert.equal(parsed[0].defaultValue, "8080");
  assert.equal(parsed[1].secret, true);
});

test("rejects secret defaults and argv exposure", () => {
  assert.throws(
    () => parseEnvDeclarations(`[[env]]
name="token"
key="TOKEN"
kind="string"
required=true
secret=true
exposure="argv-and-env"
description="secret"
overrides=["auth.token"]
environments=["prod"]
`, ".bad.toml"),
    /must be env-only/,
  );
  assert.throws(
    () => parseEnvDeclarations(`[[env]]
name="token"
key="TOKEN"
kind="string"
required=true
secret=true
exposure="env-only"
description="secret"
overrides=["auth.token"]
environments=["prod"]
default="bad"
`, ".bad.toml"),
    /must not define a default/,
  );
});

test("deterministically merges compatible duplicate keys", () => {
  const root = dir();
  write(root, ".a.toml", base);
  write(root, ".b.toml", `[[env]]
name = "port_alias"
key = "PORT"
kind = "integer"
required = false
secret = false
exposure = "argv-and-env"
description = "HTTP listener port."
overrides = ["http.port"]
environments = ["stage"]
default = 8080
`);
  const manifest = discoverEnvManifest(root);
  assert.deepEqual(manifest.variables.map((v) => v.key), ["DATABASE_URL", "PORT"]);
  const port = manifest.variables[1];
  assert.deepEqual(port.environments, ["dev", "prod", "stage"]);
  assert.deepEqual(port.overrides, ["http.port", "server.port"]);
  assert.deepEqual(port.sources, [".a.toml", ".b.toml"]);
});

test("rejects conflicting duplicate metadata rather than choosing a winner", () => {
  const root = dir();
  write(root, ".a.toml", base);
  write(root, ".b.toml", `[[env]]
name="port"
key="PORT"
kind="string"
required=false
secret=false
exposure="argv-and-env"
description="HTTP listener port."
overrides=["server.port"]
environments=["dev"]
default="8080"
`);
  assert.throws(() => discoverEnvManifest(root), /conflicting kind\/security/);
});

test("manifest.env is alphabetic, empty-valued, and contains typed provenance comments", () => {
  const root = dir();
  write(root, ".forms.toml", base);
  const text = renderManifestEnv(discoverEnvManifest(root));
  assert.ok(text.indexOf("DATABASE_URL=") < text.indexOf("PORT="));
  assert.match(text, /# type=url; required=true; secret=true; exposure=env-only/);
  assert.match(text, /# overrides=server\.database_url/);
  assert.match(text, /# sources=\.forms\.toml/);
  assert.doesNotMatch(text, /DATABASE_URL=\S/);
  assert.doesNotMatch(text, /PORT=\S/);
});

test(".cli-flags.toml must expose only argv-and-env variables as real flags", () => {
  const root = dir();
  write(root, ".forms.toml", base);
  const manifest = discoverEnvManifest(root);
  const cli = `[flags.port]
env = "PORT"
aliases = ["port"]
type = "int"
help = "Port."
`;
  const synced = syncCliEnvIndex(cli, manifest);
  assert.deepEqual(auditCliCoverage(synced, manifest), []);
  const leaked = synced + `
[flags.database]
env = "DATABASE_URL"
aliases = ["database-url"]
type = "string"
help = "bad"
`;
  assert.match(auditCliCoverage(leaked, manifest).join("\n"), /DATABASE_URL: exposure=env-only/);
});

test("sync writes manifest and CLI index, then check is stable", () => {
  const root = dir();
  write(root, ".forms.toml", base);
  write(root, ".cli-flags.toml", `[flags.port]
env = "PORT"
aliases = ["port"]
type = "int"
help = "Port."
`);
  syncRepositoryEnvManifest(root);
  const firstManifest = readFileSync(join(root, "manifest.env"), "utf8");
  const firstCli = readFileSync(join(root, ".cli-flags.toml"), "utf8");
  syncRepositoryEnvManifest(root);
  assert.equal(readFileSync(join(root, "manifest.env"), "utf8"), firstManifest);
  assert.equal(readFileSync(join(root, ".cli-flags.toml"), "utf8"), firstCli);
  assert.equal(checkRepositoryEnvManifest(root).status, "passed");
});

test("SOPS/decrypted key inventories are key-only, profile-aware, alphabetical, and secret-complete", () => {
  const root = dir();
  write(root, ".forms.toml", base);
  write(root, ".cli-flags.toml", `[flags.port]
env = "PORT"
aliases = ["port"]
type = "int"
help = "Port."
`);
  syncRepositoryEnvManifest(root);
  mkdirSync(join(root, "env", "enc"), { recursive: true });
  mkdirSync(join(root, "env", "dec"), { recursive: true });
  write(root, "env/enc/dev.env.enc", `DATABASE_URL=ENC[AES256_GCM,data:redacted,type:str]
sops_mac=ENC[AES256_GCM,data:redacted,type:str]
`);
  write(root, "env/dec/dev.env", `DATABASE_URL=redacted
`);
  assert.equal(checkRepositoryEnvManifest(root).status, "passed");

  write(root, "env/enc/prod.env.enc", `PORT=ENC[AES256_GCM,data:redacted,type:str]
DATABASE_URL=ENC[AES256_GCM,data:redacted,type:str]
`);
  const report = checkRepositoryEnvManifest(root);
  assert.equal(report.status, "failed");
  assert.match(report.findings.join("\n"), /not alphabetical/);
});

test("--sops-all style strictness can require every declared profile key", () => {
  const root = dir();
  write(root, ".forms.toml", base);
  write(root, ".cli-flags.toml", `[flags.port]
env = "PORT"
aliases = ["port"]
type = "int"
help = "Port."
`);
  syncRepositoryEnvManifest(root);
  write(root, "env/enc/dev.env.enc", `DATABASE_URL=ENC[AES256_GCM,data:redacted,type:str]
`);
  assert.equal(checkRepositoryEnvManifest(root).status, "passed");
  const strict = checkRepositoryEnvManifest(root, { sopsAll: true });
  assert.equal(strict.status, "failed");
  assert.match(strict.findings.join("\n"), /missing declared key PORT/);
});
