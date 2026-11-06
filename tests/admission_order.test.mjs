// Execute the real C parser CLI and assert that authorization-style Boolean
// admission is last-write, fail-closed, and insensitive to ambient defaults.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const cli = process.env.F2E_TEST_CLI ??
  resolve(dirname(fileURLToPath(import.meta.url)), '../build/flags2env');

const config = `
[env]
files = []
[parse]
allow_unknown = false
allow_separated_values = true
unknown_options_env = "ADMIT_UNKNOWN"
errors_env = "ADMIT_ERRORS"
positionals_env = "ADMIT_POSITIONALS"
[flags.allow]
env = "ADMIT_ALLOW"
aliases = ["allow", "permit"]
type = "bool"
default = "false"
[flags.audit]
env = "ADMIT_AUDIT"
aliases = ["audit"]
type = "bool"
default = "true"
[flags.label]
env = "ADMIT_LABEL"
aliases = ["label"]
type = "string"
`;

function resolveFlags(argv, environment = {}) {
  const cwd = mkdtempSync(join(tmpdir(), 'f2e-admit-'));
  try {
    writeFileSync(join(cwd, '.cli-flags.toml'), config);
    const result = spawnSync(cli, ['app', ...argv], {
      cwd,
      encoding: 'utf8',
      timeout: 10_000,
      maxBuffer: 1024 * 1024,
      env: {
        PATH: process.env.PATH,
        HOME: join(cwd, 'empty-home'),
        FLAGS2ENV_DOTENV: '0',
        CI: '1',
        ...environment,
      },
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
}

function diagnostics(result, key) {
  return JSON.parse(result[key] ?? '[]');
}

function admitted(result) {
  assert.deepEqual(diagnostics(result, 'ADMIT_UNKNOWN'), []);
  assert.deepEqual(diagnostics(result, 'ADMIT_ERRORS'), []);
}

test('explicit deny overrides every earlier true assignment and ambient approval', () => {
  for (const deny of ['--no-allow', '--!allow', '--allow!', '--allow=false']) {
    for (const allow of ['--allow', '--allow=true', '--permit']) {
      const result = resolveFlags([allow, deny], { ADMIT_ALLOW: 'true' });
      admitted(result);
      assert.equal(result.ADMIT_ALLOW, 'false', `${allow} then ${deny}`);
    }
  }
});

test('repeated denial is idempotent, not a toggle to true', () => {
  for (const deny of ['--no-allow', '--!allow', '--allow!']) {
    const result = resolveFlags([deny, deny, deny], { ADMIT_ALLOW: 'true' });
    admitted(result);
    assert.equal(result.ADMIT_ALLOW, 'false');
  }
});

test('later explicit approval wins only when it appears after the denial', () => {
  for (const deny of ['--no-allow', '--!allow', '--allow!', '--allow=false']) {
    const result = resolveFlags([deny, '--allow']);
    admitted(result);
    assert.equal(result.ADMIT_ALLOW, 'true');
  }
});

test('end-of-options marker blocks permission-shaped arguments from being parsed', () => {
  const result = resolveFlags(['--', '--allow', '--no-audit', '--!allow']);
  admitted(result);
  assert.equal(result.ADMIT_ALLOW, 'false');
  assert.equal(result.ADMIT_AUDIT, 'true');
  assert.deepEqual(
    diagnostics(result, 'ADMIT_POSITIONALS'),
    ['--allow', '--no-audit', '--!allow'],
  );
});

test('malformed or nonboolean negations never change permissions', () => {
  for (const invalid of [
    '--!label', '--label!', '--!allow=true', '--allow!=false',
    '--!!allow', '--allow!!', '--!missing', '--missing!',
  ]) {
    const result = resolveFlags([invalid]);
    assert.equal(result.ADMIT_ALLOW, 'false', invalid);
    assert.ok(
      diagnostics(result, 'ADMIT_UNKNOWN').includes(invalid) ||
      diagnostics(result, 'ADMIT_ERRORS').length > 0,
      `unrecognized permission-shaped token ${invalid} must not be accepted`,
    );
  }
});

test('values resembling switches remain opaque values, never executable flags', () => {
  const result = resolveFlags(['--label=--allow', '--no-audit']);
  admitted(result);
  assert.equal(result.ADMIT_LABEL, '--allow');
  assert.equal(result.ADMIT_ALLOW, 'false');
  assert.equal(result.ADMIT_AUDIT, 'false');
});
