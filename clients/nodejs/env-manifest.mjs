import { createHash } from "node:crypto";
import {
  lstatSync,
  readdirSync,
  readFileSync,
  realpathSync,
  writeFileSync,
  existsSync,
} from "node:fs";
import { join, resolve } from "node:path";

export const ENV_MANIFEST_SCHEMA = "ores.env-manifest.v1";
export const CLI_INDEX_BEGIN = "# BEGIN flags2env env-manifest v1";
export const CLI_INDEX_END = "# END flags2env env-manifest v1";

const KINDS = new Set([
  "string",
  "bool",
  "integer",
  "double",
  "json",
  "url",
  "duration-ms",
  "string-list",
  "integer-list",
]);
const EXPOSURES = new Set(["env-only", "argv-and-env"]);
const ENVIRONMENTS = new Set(["dev", "stage", "prod"]);
const ENV_KEY = /^[A-Z_][A-Z0-9_]*$/;
const BINDING_NAME = /^[a-z][a-z0-9_]*$/;
const OVERRIDE_PATH = /^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*(?:\[\])?$/;
const ENV_FIELDS = new Set([
  "name",
  "key",
  "kind",
  "required",
  "secret",
  "exposure",
  "description",
  "overrides",
  "environments",
  "default",
  "default_value",
  "defaultValue",
]);

function fail(message) {
  throw new Error(`env-manifest: ${message}`);
}

function bytewise(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

function stripTomlComment(line) {
  let single = false;
  let double = false;
  let escaped = false;
  for (let index = 0; index < line.length; index += 1) {
    const ch = line[index];
    if (double) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === '"') {
        double = false;
      }
      continue;
    }
    if (single) {
      if (ch === "'") single = false;
      continue;
    }
    if (ch === '"') {
      double = true;
      continue;
    }
    if (ch === "'") {
      single = true;
      continue;
    }
    if (ch === "#") return line.slice(0, index);
  }
  return line;
}

function splitTomlArray(inner, source, lineNumber) {
  const parts = [];
  let start = 0;
  let single = false;
  let double = false;
  let escaped = false;
  for (let index = 0; index < inner.length; index += 1) {
    const ch = inner[index];
    if (double) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') double = false;
      continue;
    }
    if (single) {
      if (ch === "'") single = false;
      continue;
    }
    if (ch === '"') {
      double = true;
      continue;
    }
    if (ch === "'") {
      single = true;
      continue;
    }
    if (ch === ",") {
      parts.push(inner.slice(start, index).trim());
      start = index + 1;
    }
  }
  if (single || double) fail(`${source}:${lineNumber}: unterminated string in array`);
  const tail = inner.slice(start).trim();
  if (tail) parts.push(tail);
  return parts;
}

function parseTomlString(raw, source, lineNumber) {
  if (raw.startsWith('"')) {
    try {
      const value = JSON.parse(raw);
      if (typeof value !== "string") throw new Error("not a string");
      return value;
    } catch {
      fail(`${source}:${lineNumber}: invalid TOML basic string`);
    }
  }
  if (raw.startsWith("'") && raw.endsWith("'") && raw.length >= 2) {
    return raw.slice(1, -1);
  }
  fail(`${source}:${lineNumber}: expected a quoted string`);
}

function parseTomlValue(raw, source, lineNumber) {
  const value = raw.trim();
  if (value === "true") return true;
  if (value === "false") return false;
  if (value.startsWith('"') || value.startsWith("'")) {
    return parseTomlString(value, source, lineNumber);
  }
  if (value.startsWith("[") && value.endsWith("]")) {
    const inner = value.slice(1, -1).trim();
    if (!inner) return [];
    return splitTomlArray(inner, source, lineNumber).map((part) =>
      parseTomlString(part, source, lineNumber),
    );
  }
  if (/^[+-]?\d+(?:\.\d+)?$/.test(value)) return value;
  fail(`${source}:${lineNumber}: unsupported env metadata value`);
}

function finishEnvBlock(block, source, lineNumber, out) {
  if (!block) return;
  const defaults = ["default", "default_value", "defaultValue"].filter((key) =>
    Object.hasOwn(block, key),
  );
  if (defaults.length > 1) {
    fail(`${source}:${lineNumber}: env declaration has multiple default spellings`);
  }
  const declaration = {
    name: block.name,
    key: block.key,
    kind: block.kind,
    required: block.required,
    secret: block.secret,
    exposure: block.exposure,
    description: block.description,
    overrides: block.overrides,
    environments: block.environments,
  };
  if (defaults.length === 1) declaration.defaultValue = String(block[defaults[0]]);
  validateDeclaration(declaration, source, lineNumber);
  out.push(declaration);
}

export function parseEnvDeclarations(content, source = "<toml>") {
  const out = [];
  let current = null;
  const lines = String(content).split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const lineNumber = index + 1;
    const line = stripTomlComment(lines[index]).trim();
    if (!line) continue;
    if (line === "[[env]]") {
      finishEnvBlock(current, source, lineNumber - 1, out);
      current = {};
      continue;
    }
    if (line.startsWith("[") && line.endsWith("]")) {
      finishEnvBlock(current, source, lineNumber - 1, out);
      current = null;
      continue;
    }
    if (!current) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) fail(`${source}:${lineNumber}: malformed [[env]] assignment`);
    const key = line.slice(0, eq).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      fail(`${source}:${lineNumber}: invalid [[env]] key ${key}`);
    }
    if (!ENV_FIELDS.has(key)) fail(`${source}:${lineNumber}: unknown [[env]] key ${key}`);
    if (Object.hasOwn(current, key)) fail(`${source}:${lineNumber}: duplicate [[env]] key ${key}`);
    current[key] = parseTomlValue(line.slice(eq + 1), source, lineNumber);
  }
  finishEnvBlock(current, source, lines.length, out);
  return out;
}

export function validateDeclaration(value, source = "<declaration>", lineNumber = 0) {
  const where = `${source}${lineNumber ? `:${lineNumber}` : ""}`;
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${where}: declaration must be an object`);
  if (!BINDING_NAME.test(value.name || "")) fail(`${where}: invalid binding name`);
  if (!ENV_KEY.test(value.key || "")) fail(`${where}: invalid environment key for ${value.name || "<unknown>"}`);
  if (!KINDS.has(value.kind)) fail(`${where}: unsupported kind for ${value.key || value.name}`);
  if (typeof value.required !== "boolean") fail(`${where}: required must be boolean for ${value.key || value.name}`);
  if (typeof value.secret !== "boolean") fail(`${where}: secret must be boolean for ${value.key || value.name}`);
  if (!EXPOSURES.has(value.exposure)) fail(`${where}: invalid exposure for ${value.key || value.name}`);
  if (value.secret && value.exposure !== "env-only") fail(`${where}: secret ${value.key} must be env-only`);
  if (value.secret && Object.hasOwn(value, "defaultValue")) fail(`${where}: secret ${value.key} must not define a default`);
  if (typeof value.description !== "string" || !value.description.trim() || value.description.length > 512) {
    fail(`${where}: description is required for ${value.key || value.name}`);
  }
  if (!Array.isArray(value.overrides) || value.overrides.length === 0 || value.overrides.length > 32) {
    fail(`${where}: overrides must be a non-empty bounded list for ${value.key || value.name}`);
  }
  if (new Set(value.overrides).size !== value.overrides.length) fail(`${where}: duplicate override path for ${value.key}`);
  for (const path of value.overrides) {
    if (typeof path !== "string" || !OVERRIDE_PATH.test(path)) fail(`${where}: invalid override path for ${value.key}`);
  }
  if (!Array.isArray(value.environments) || value.environments.length === 0 || value.environments.length > 3) {
    fail(`${where}: environments must be a non-empty subset for ${value.key || value.name}`);
  }
  if (new Set(value.environments).size !== value.environments.length) fail(`${where}: duplicate environment profile for ${value.key}`);
  for (const environment of value.environments) {
    if (!ENVIRONMENTS.has(environment)) fail(`${where}: invalid environment profile ${environment} for ${value.key}`);
  }
  if (Object.hasOwn(value, "defaultValue") && typeof value.defaultValue !== "string") {
    fail(`${where}: defaultValue must normalize to text for ${value.key}`);
  }
  return value;
}

function rootTomlFiles(root) {
  const canonicalRoot = realpathSync(root);
  const files = [];
  for (const entry of readdirSync(canonicalRoot, { withFileTypes: true })) {
    if (!entry.name.endsWith(".toml") || entry.name === ".cli-flags.toml") continue;
    const path = join(canonicalRoot, entry.name);
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) fail(`${entry.name}: root TOML symlinks are not allowed in env discovery`);
    if (stat.isFile()) files.push(entry.name);
  }
  return { canonicalRoot, files: files.sort(bytewise) };
}

export function discoverEnvDeclarations(root = ".") {
  const { canonicalRoot, files } = rootTomlFiles(root);
  const declarations = [];
  for (const source of files) {
    const parsed = parseEnvDeclarations(readFileSync(join(canonicalRoot, source), "utf8"), source);
    for (const declaration of parsed) declarations.push({ ...declaration, source });
  }
  return declarations;
}

function equalScalarMetadata(left, right) {
  return (
    left.kind === right.kind &&
    left.required === right.required &&
    left.secret === right.secret &&
    left.exposure === right.exposure &&
    left.description === right.description &&
    (left.defaultValue ?? null) === (right.defaultValue ?? null)
  );
}

export function resolveEnvManifest(declarations) {
  const byKey = new Map();
  for (const sourceDeclaration of declarations) {
    const { source = "<unknown>", ...declaration } = sourceDeclaration;
    validateDeclaration(declaration, source);
    const existing = byKey.get(declaration.key);
    if (!existing) {
      byKey.set(declaration.key, {
        key: declaration.key,
        kind: declaration.kind,
        required: declaration.required,
        secret: declaration.secret,
        exposure: declaration.exposure,
        description: declaration.description,
        ...(Object.hasOwn(declaration, "defaultValue") ? { defaultValue: declaration.defaultValue } : {}),
        overrides: [...declaration.overrides],
        environments: [...declaration.environments],
        sources: [source],
      });
      continue;
    }
    if (!equalScalarMetadata(existing, declaration)) {
      fail(`${declaration.key}: conflicting kind/security/exposure/description/default metadata across ${existing.sources.join(", ")} and ${source}`);
    }
    existing.overrides.push(...declaration.overrides);
    existing.environments.push(...declaration.environments);
    existing.sources.push(source);
  }

  const variables = [...byKey.values()]
    .map((variable) => ({
      ...variable,
      overrides: [...new Set(variable.overrides)].sort(bytewise),
      environments: [...new Set(variable.environments)].sort(bytewise),
      sources: [...new Set(variable.sources)].sort(bytewise),
    }))
    .sort((a, b) => bytewise(a.key, b.key));

  return { schemaVersion: ENV_MANIFEST_SCHEMA, variables };
}

export function discoverEnvManifest(root = ".") {
  return resolveEnvManifest(discoverEnvDeclarations(root));
}

export function manifestDigest(manifest) {
  return createHash("sha256").update(`${JSON.stringify(manifest)}\n`).digest("hex");
}

function commentValue(value) {
  return String(value).replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim();
}

export function renderManifestEnv(manifest) {
  const digest = manifestDigest(manifest);
  const lines = [
    "# Generated by flags-2-env env-manifest. Values intentionally empty.",
    `# schema=${manifest.schemaVersion} sha256=${digest}`,
    "# Do not store secrets or runtime values in this file.",
    "",
  ];
  for (const variable of manifest.variables) {
    lines.push(
      `# type=${variable.kind}; required=${variable.required}; secret=${variable.secret}; exposure=${variable.exposure}; environments=${variable.environments.join(",")}`,
      `# overrides=${variable.overrides.join(",")}`,
      `# sources=${variable.sources.join(",")}`,
      `# ${commentValue(variable.description)}`,
      `${variable.key}=`,
      "",
    );
  }
  return `${lines.join("\n").replace(/\n+$/u, "")}\n`;
}

export function renderCliEnvIndex(manifest) {
  const digest = manifestDigest(manifest);
  const lines = [
    CLI_INDEX_BEGIN,
    `# schema=${manifest.schemaVersion} sha256=${digest}`,
  ];
  for (const variable of manifest.variables) {
    lines.push(
      `# env ${variable.key} kind=${variable.kind} required=${variable.required} secret=${variable.secret} exposure=${variable.exposure} environments=${variable.environments.join(",")} sources=${variable.sources.join(",")} overrides=${variable.overrides.join(",")}`,
      `#   ${commentValue(variable.description)}`,
    );
  }
  lines.push(CLI_INDEX_END);
  return `${lines.join("\n")}\n`;
}

function findCliIndexBounds(content) {
  const start = content.indexOf(CLI_INDEX_BEGIN);
  const endStart = content.indexOf(CLI_INDEX_END);
  if (start < 0 && endStart < 0) return null;
  if (start < 0 || endStart < start) fail(".cli-flags.toml has a malformed env-manifest index block");
  const afterEnd = endStart + CLI_INDEX_END.length;
  if (content.indexOf(CLI_INDEX_BEGIN, start + CLI_INDEX_BEGIN.length) >= 0 ||
      content.indexOf(CLI_INDEX_END, afterEnd) >= 0) {
    fail(".cli-flags.toml contains multiple env-manifest index blocks");
  }
  return { start, end: content[afterEnd] === "\n" ? afterEnd + 1 : afterEnd };
}

export function syncCliEnvIndex(content, manifest) {
  const generated = renderCliEnvIndex(manifest);
  const bounds = findCliIndexBounds(content);
  if (!bounds) {
    const prefix = content && !content.endsWith("\n") ? `${content}\n` : content;
    return `${prefix || ""}${prefix ? "\n" : ""}${generated}`;
  }
  return `${content.slice(0, bounds.start)}${generated}${content.slice(bounds.end)}`;
}

export function parseCliFlagEnvKeys(content) {
  const keys = new Map();
  let flag = null;
  const lines = String(content).split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = stripTomlComment(lines[index]).trim();
    if (!line) continue;
    const table = line.match(/^\[flags\.([A-Za-z0-9_.-]+)\]$/);
    if (table) {
      flag = table[1];
      continue;
    }
    if (line.startsWith("[") && line.endsWith("]")) {
      flag = null;
      continue;
    }
    if (!flag) continue;
    const match = line.match(/^env\s*=\s*(.+)$/);
    if (!match) continue;
    const key = parseTomlString(match[1].trim(), ".cli-flags.toml", index + 1);
    if (!ENV_KEY.test(key)) fail(`.cli-flags.toml:${index + 1}: invalid env key`);
    if (keys.has(key)) fail(`.cli-flags.toml:${index + 1}: ${key} is owned by multiple flags`);
    keys.set(key, flag);
  }
  return keys;
}

export function auditCliCoverage(cliContent, manifest) {
  const findings = [];
  const flagKeys = parseCliFlagEnvKeys(cliContent);
  for (const variable of manifest.variables) {
    const owner = flagKeys.get(variable.key);
    if (variable.exposure === "argv-and-env" && !owner) {
      findings.push(`${variable.key}: exposure=argv-and-env but no [flags.*] entry references it`);
    }
    if (variable.exposure === "env-only" && owner) {
      findings.push(`${variable.key}: exposure=env-only but flags.${owner} exposes it on argv`);
    }
  }
  const expectedIndex = renderCliEnvIndex(manifest);
  const bounds = findCliIndexBounds(cliContent);
  if (!bounds) findings.push(".cli-flags.toml is missing the generated env-manifest index block");
  else if (cliContent.slice(bounds.start, bounds.end) !== expectedIndex) {
    findings.push(".cli-flags.toml env-manifest index is stale");
  }
  return findings;
}

export function parseDotenvKeys(content) {
  const keys = [];
  const seen = new Set();
  for (const raw of String(content).split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const match = line.match(/^([A-Z_][A-Z0-9_]*)=/);
    if (!match) continue;
    const key = match[1];
    if (seen.has(key)) fail(`dotenv inventory contains duplicate key ${key}`);
    seen.add(key);
    keys.push(key);
  }
  return keys;
}

function auditProfileFile(path, profile, manifest, { requireAll = false } = {}) {
  if (!existsSync(path)) return { path, profile, status: "not-present", findings: [] };
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    return { path, profile, status: "failed", findings: [`${path}: must be a regular file`] };
  }
  let keys;
  try {
    keys = parseDotenvKeys(readFileSync(path, "utf8"));
  } catch (error) {
    return { path, profile, status: "failed", findings: [error.message] };
  }
  const findings = [];
  const declared = manifest.variables.filter((variable) => variable.environments.includes(profile));
  const declaredKeys = new Set(declared.map((variable) => variable.key));
  for (const key of keys) {
    if (!declaredKeys.has(key)) findings.push(`${path}: undeclared environment key ${key}`);
  }
  const requiredKeys = declared
    .filter((variable) => requireAll || variable.secret)
    .map((variable) => variable.key);
  const actual = new Set(keys);
  for (const key of requiredKeys) {
    if (!actual.has(key)) findings.push(`${path}: missing ${requireAll ? "declared" : "secret"} key ${key}`);
  }
  const sorted = [...keys].sort(bytewise);
  if (JSON.stringify(keys) !== JSON.stringify(sorted)) findings.push(`${path}: application environment keys are not alphabetical`);
  return { path, profile, status: findings.length ? "failed" : "passed", findings };
}

export function auditSopsInventories(root, manifest, options = {}) {
  const reports = [];
  for (const profile of ["dev", "stage", "prod"]) {
    reports.push(
      auditProfileFile(join(root, "env", "enc", `${profile}.env.enc`), profile, manifest, {
        requireAll: options.sopsAll === true,
      }),
    );
    reports.push(
      auditProfileFile(join(root, "env", "dec", `${profile}.env`), profile, manifest, {
        requireAll: options.decAll === true,
      }),
    );
  }
  return reports;
}

export function checkRepositoryEnvManifest(root = ".", options = {}) {
  const canonicalRoot = realpathSync(root);
  const declarations = discoverEnvDeclarations(canonicalRoot);
  const manifest = resolveEnvManifest(declarations);
  const findings = [];
  const manifestPath = resolve(canonicalRoot, options.manifestPath || "manifest.env");
  const cliPath = resolve(canonicalRoot, options.cliPath || ".cli-flags.toml");
  const expectedManifest = renderManifestEnv(manifest);
  if (!existsSync(manifestPath)) findings.push("manifest.env is missing");
  else if (readFileSync(manifestPath, "utf8") !== expectedManifest) findings.push("manifest.env is stale");

  let cliStatus = "not-present";
  if (existsSync(cliPath)) {
    cliStatus = "checked";
    findings.push(...auditCliCoverage(readFileSync(cliPath, "utf8"), manifest));
  }

  const sops = auditSopsInventories(canonicalRoot, manifest, options);
  for (const report of sops) findings.push(...report.findings);
  return {
    schema: "flags2env.env-manifest-check/v1",
    status: findings.length ? "failed" : "passed",
    digest: manifestDigest(manifest),
    sources: [...new Set(declarations.map((item) => item.source))].sort(bytewise),
    variableCount: manifest.variables.length,
    cliStatus,
    sops,
    findings,
  };
}

export function syncRepositoryEnvManifest(root = ".", options = {}) {
  const canonicalRoot = realpathSync(root);
  const manifest = discoverEnvManifest(canonicalRoot);
  const manifestPath = resolve(canonicalRoot, options.manifestPath || "manifest.env");
  writeFileSync(manifestPath, renderManifestEnv(manifest), { mode: 0o644 });
  const cliPath = resolve(canonicalRoot, options.cliPath || ".cli-flags.toml");
  if (existsSync(cliPath)) {
    const stat = lstatSync(cliPath);
    if (!stat.isFile() || stat.isSymbolicLink()) fail(".cli-flags.toml must be a regular file");
    writeFileSync(cliPath, syncCliEnvIndex(readFileSync(cliPath, "utf8"), manifest), { mode: 0o644 });
  }
  return manifest;
}

function parseCliArgs(args) {
  let action = "check";
  let root = ".";
  let manifestPath;
  let cliPath;
  let sopsAll = false;
  let decAll = false;
  let sawRoot = false;
  let index = 0;
  if (args[0] && !args[0].startsWith("-")) {
    action = args[0];
    index = 1;
  }
  for (; index < args.length; index += 1) {
    const token = args[index];
    const take = (name) => {
      if (index + 1 >= args.length) fail(`${name} requires a value`);
      return args[++index];
    };
    if (token === "--root") root = take("--root");
    else if (token.startsWith("--root=")) root = token.slice(7);
    else if (token === "--manifest") manifestPath = take("--manifest");
    else if (token.startsWith("--manifest=")) manifestPath = token.slice(11);
    else if (token === "--cli") cliPath = take("--cli");
    else if (token.startsWith("--cli=")) cliPath = token.slice(6);
    else if (token === "--sops-all") sopsAll = true;
    else if (token === "--dec-all") decAll = true;
    else if (!token.startsWith("-") && !sawRoot && root === ".") {
      root = token;
      sawRoot = true;
    } else fail(`unknown env-manifest option ${token}`);
  }
  return { action, root, manifestPath, cliPath, sopsAll, decAll };
}

export function runEnvManifestCli(args, streams = process) {
  const options = parseCliArgs(args);
  if (["help", "-h", "--help"].includes(options.action)) {
    streams.stdout.write(
      "usage:\n" +
      "  f2e env-manifest check [root] [--manifest path] [--cli path] [--sops-all] [--dec-all]\n" +
      "  f2e env-manifest sync [root] [--manifest path] [--cli path]\n" +
      "  f2e env-manifest generate [root]\n" +
      "  f2e env-manifest json [root]\n",
    );
    return 0;
  }
  if (options.action === "generate") {
    streams.stdout.write(renderManifestEnv(discoverEnvManifest(options.root)));
    return 0;
  }
  if (options.action === "json") {
    streams.stdout.write(`${JSON.stringify(discoverEnvManifest(options.root), null, 2)}\n`);
    return 0;
  }
  if (options.action === "sync") {
    const manifest = syncRepositoryEnvManifest(options.root, options);
    streams.stdout.write(`${JSON.stringify({ schema: "flags2env.env-manifest-sync/v1", status: "passed", digest: manifestDigest(manifest), variableCount: manifest.variables.length })}\n`);
    return 0;
  }
  if (options.action === "check") {
    const report = checkRepositoryEnvManifest(options.root, options);
    streams.stdout.write(`${JSON.stringify(report)}\n`);
    return report.status === "passed" ? 0 : 2;
  }
  fail(`unknown env-manifest action ${options.action}`);
}

export default {
  discoverEnvDeclarations,
  discoverEnvManifest,
  parseEnvDeclarations,
  resolveEnvManifest,
  renderManifestEnv,
  renderCliEnvIndex,
  syncCliEnvIndex,
  auditCliCoverage,
  auditSopsInventories,
  checkRepositoryEnvManifest,
  syncRepositoryEnvManifest,
  runEnvManifestCli,
};
