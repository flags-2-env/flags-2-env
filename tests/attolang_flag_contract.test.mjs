// Native flags2env CLI parsing for AttoLang permission-shaped flags.
// These are configuration values, NOT authorizations to access resources.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, rmSync, writeFileSync, readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const cli=process.env.F2E_TEST_CLI ?? join(root,'build/flags2env');
const config=[
  '[env]', 'files = []', '[parse]', 'allow_unknown = false',
  'allow_separated_values = true',
  'unknown_options_env = "ATTO_UNKNOWN"',
  'errors_env = "ATTO_ERRORS"',
  'positionals_env = "ATTO_POSITIONALS"',
  '[flags.read]', 'env = "ATTO_ALLOW_READ"',
  'aliases = ["allow-read"]', 'type = "bool"', 'default = "false"',
  '[flags.net]', 'env = "ATTO_ALLOW_NET"',
  'aliases = ["allow-net"]', 'type = "bool"', 'default = "false"',
  '[flags.env]', 'env = "ATTO_ALLOW_ENV"',
  'aliases = ["allow-env"]', 'type = "bool"', 'default = "false"',
  '',
].join('\n');

function run(args, ambient={}) {
  const cwd=mkdtempSync(join(tmpdir(),'flags2env-atto-'));
  try {
    writeFileSync(join(cwd,'.cli-flags.toml'),config);
    const out=spawnSync(cli,['app',...args],{
      cwd,encoding:'utf8',timeout:10000,maxBuffer:1024*1024,
      env:{PATH:process.env.PATH,HOME:join(cwd,'isolated-home'),
        FLAGS2ENV_DOTENV:'0',CI:'1',F2E_FORCE_CI:'1',...ambient},
    });
    assert.ifError(out.error);
    assert.equal(out.status,0,out.stderr);
    return JSON.parse(out.stdout);
  } finally {rmSync(cwd,{recursive:true,force:true});}
}
function list(v,key){return JSON.parse(v[key]??'[]');}

for(const key of ['ATTO_ALLOW_READ','ATTO_ALLOW_NET','ATTO_ALLOW_ENV']){
  test(key + ' is denied by default',()=>{
    assert.equal(run([])[key],'false');
  });
}
test('only expressly declared capabilities are enabled',()=>{
  const r=run(['--allow-read']);
  assert.equal(r.ATTO_ALLOW_READ,'true');
  assert.equal(r.ATTO_ALLOW_NET,'false');
  assert.equal(r.ATTO_ALLOW_ENV,'false');
  assert.deepEqual(list(r,'ATTO_ERRORS'),[]);
});
test('explicit negation is idempotent and overrides ambient allow',()=>{
  const r=run(['--allow-read','--no-allow-read','--no-allow-read'],{
    ATTO_ALLOW_READ:'true'});
  assert.equal(r.ATTO_ALLOW_READ,'false');
});
test('end marker prevents permission escalation',()=>{
  const r=run(['--','--allow-net']);
  assert.equal(r.ATTO_ALLOW_NET,'false');
  assert.ok(list(r,'ATTO_POSITIONALS').includes('--allow-net'));
});
test('undeclared permission does not promote a known flag',()=>{
  const r=run(['--allow-all']);
  assert.equal(r.ATTO_ALLOW_READ,'false');
  assert.equal(r.ATTO_ALLOW_NET,'false');
  assert.ok(list(r,'ATTO_UNKNOWN').includes('--allow-all'));
});
test('AttoLang authority gate is separately source-gated, not executed',()=>{
  const s=readFileSync(join(root,'examples/attolang/permission_gate.atto'),'utf8');
  for(const v of ['define module permission_gate','admitted(',
    'explicit_allow && !explicit_deny','matching_scope && capability_live',
    'self_check()']) assert.ok(s.includes(v),v);
});
