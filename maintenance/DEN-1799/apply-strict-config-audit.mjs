#!/usr/bin/env node
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

function replaceOnce(text, before, after, label) {
  const count = text.split(before).length - 1;
  if (count !== 1) {
    throw new Error(`${label}: expected exactly one anchor, found ${count}`);
  }
  return text.replace(before, after);
}

const sourcePath = 'src/parser.c';
const sourceBefore = fs.readFileSync(sourcePath, 'utf8');
let source = sourceBefore;

source = replaceOnce(
  source,
  `  unsigned help_exclude_columns;\n  int invalid_help_columns;\n  int invalid_help_exclude_columns;\n} F2EConfig;`,
  `  unsigned help_exclude_columns;\n  int invalid_help_columns;\n  int invalid_help_exclude_columns;\n  /* First unknown table/key encountered while parsing the authoring contract.\n     Values are deliberately never copied here: audit diagnostics must identify\n     the unsupported spelling without reflecting possible secret material. */\n  char invalid_config_entry[F2E_MAX_VALUE];\n  int has_invalid_config_entry;\n} F2EConfig;`,
  'F2EConfig strict-entry fields',
);

source = replaceOnce(
  source,
  `static int f2e_load_config(const char *config_path, F2EConfig *config) {`,
  `static void f2e_record_unknown_config_table(F2EConfig *config, const char *table) {\n  if (!config || config->has_invalid_config_entry) {\n    return;\n  }\n  snprintf(config->invalid_config_entry, sizeof(config->invalid_config_entry),\n           "unknown config table [%s]", table ? table : "");\n  config->has_invalid_config_entry = 1;\n}\n\nstatic void f2e_record_unknown_config_key(F2EConfig *config, const char *section, const char *key) {\n  if (!config || config->has_invalid_config_entry) {\n    return;\n  }\n  snprintf(config->invalid_config_entry, sizeof(config->invalid_config_entry),\n           "unknown key \\\"%s\\\" in [%s]", key ? key : "", section ? section : "root");\n  config->has_invalid_config_entry = 1;\n}\n\nstatic int f2e_load_config(const char *config_path, F2EConfig *config) {`,
  'strict-entry recorders',
);

source = replaceOnce(
  source,
  `      } else {\n        current = NULL;\n        section = F2E_SECTION_NONE;\n      }\n      continue;`,
  `      } else {\n        current = NULL;\n        section = F2E_SECTION_NONE;\n        f2e_record_unknown_config_table(config, table);\n      }\n      continue;`,
  'unknown table handling',
);

source = replaceOnce(
  source,
  `        if (f2e_parse_config_bool(value, &parsed)) {\n          config->dotenv_override = parsed;\n        }\n      }\n      continue;\n    }\n\n    if (section == F2E_SECTION_HELP) {`,
  `        if (f2e_parse_config_bool(value, &parsed)) {\n          config->dotenv_override = parsed;\n        }\n      } else {\n        f2e_record_unknown_config_key(config, "parse", key);\n      }\n      continue;\n    }\n\n    if (section == F2E_SECTION_HELP) {`,
  'parse unknown key handling',
);

source = replaceOnce(
  source,
  `        } else {\n          config->invalid_help_exclude_columns = 1;\n        }\n      }\n      continue;\n    }\n\n    if (section == F2E_SECTION_ENV_AUDIT) {`,
  `        } else {\n          config->invalid_help_exclude_columns = 1;\n        }\n      } else {\n        f2e_record_unknown_config_key(config, "help", key);\n      }\n      continue;\n    }\n\n    if (section == F2E_SECTION_ENV_AUDIT) {`,
  'help unknown key handling',
);

source = replaceOnce(
  source,
  `          config->default_order = order;\n          config->default_order_set = 1;\n        }\n      }\n      continue;\n    }\n\n    if (section == F2E_SECTION_ORDER) {`,
  `          config->default_order = order;\n          config->default_order_set = 1;\n        }\n      } else {\n        f2e_record_unknown_config_key(config, "env", key);\n      }\n      continue;\n    }\n\n    if (section == F2E_SECTION_ORDER) {`,
  'env unknown key handling',
);

source = replaceOnce(
  source,
  `          command->allow_unknown = parsed;\n          command->allow_unknown_set = 1;\n        }\n      }\n      continue;\n    }\n\n    if (section != F2E_SECTION_FLAG || !current) {\n      continue;\n    }`,
  `          command->allow_unknown = parsed;\n          command->allow_unknown_set = 1;\n        }\n      } else {\n        f2e_record_unknown_config_key(config, "commands.*", key);\n      }\n      continue;\n    }\n\n    if (section == F2E_SECTION_NONE) {\n      f2e_record_unknown_config_key(config, "root", key);\n      continue;\n    }\n\n    if (section != F2E_SECTION_FLAG || !current) {\n      continue;\n    }`,
  'command/root unknown key handling',
);

source = replaceOnce(
  source,
  `    } else if (f2e_streq(key, "help") || f2e_streq(key, "description") || f2e_streq(key, "example")) {\n      char parsed[F2E_MAX_VALUE];\n      if (f2e_parse_bare_value(value, parsed, sizeof(parsed))) {\n        f2e_strlcpy(current->help, parsed, sizeof(current->help));\n      }\n    }\n  }\n\n  fclose(file);`,
  `    } else if (f2e_streq(key, "help") || f2e_streq(key, "description") || f2e_streq(key, "example")) {\n      char parsed[F2E_MAX_VALUE];\n      if (f2e_parse_bare_value(value, parsed, sizeof(parsed))) {\n        f2e_strlcpy(current->help, parsed, sizeof(current->help));\n      }\n    } else {\n      f2e_record_unknown_config_key(config, "flags.*", key);\n    }\n  }\n\n  fclose(file);`,
  'flag unknown key handling',
);

source = replaceOnce(
  source,
  `static void f2e_audit_config_semantics(const F2EConfig *config, F2EAudit *audit) {\n  if (config->flag_count == 0 && config->command_count == 0) {`,
  `static void f2e_audit_config_semantics(const F2EConfig *config, F2EAudit *audit) {\n  if (config->has_invalid_config_entry) {\n    f2e_audit_add(audit, 1, "%s", config->invalid_config_entry);\n  }\n  if (config->flag_count == 0 && config->command_count == 0) {`,
  'audit unknown entry gate',
);

const tracked = execFileSync('git', ['ls-files'], { encoding: 'utf8' })
  .split(/\r?\n/)
  .filter(Boolean);
const parserCopies = tracked.filter((path) => path === sourcePath || path.endsWith('/parser.c'));
let synchronized = 0;
for (const path of parserCopies) {
  const current = fs.readFileSync(path, 'utf8');
  if (current === sourceBefore) {
    fs.writeFileSync(path, source);
    synchronized += 1;
  }
}
if (synchronized < 2) {
  throw new Error(`expected source plus vendored parser copies to synchronize; updated ${synchronized}`);
}

const testsPath = 'tests/run.sh';
let tests = fs.readFileSync(testsPath, 'utf8');
const testsAnchor = `INVALID_TYPE_CONFIG="$ROOT_DIR/tests/audit-invalid-type/.cli-flags.toml"\n`;
const strictCases = `UNKNOWN_KEY_CONFIG="$ROOT_DIR/tests/audit-invalid-unknown-key/.cli-flags.toml"\nset +e\nactual="$("$CLI" audit "$UNKNOWN_KEY_CONFIG")"\nstatus=$?\nset -e\nexpected='{\"ok\":false,\"errorCount\":1,\"warningCount\":0,\"errors\":[\"unknown key \\\"mystery\\\" in [flags.*]\"],\"warnings\":[]}'\nif [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then\n  printf 'Unknown config key must fail closed.\\nExpected: %s\\nActual: %s\\n' "$expected" "$actual" >&2\n  exit 1\nfi\n\nUNKNOWN_TABLE_CONFIG="$ROOT_DIR/tests/audit-invalid-unknown-table/.cli-flags.toml"\nset +e\nactual="$("$CLI" audit "$UNKNOWN_TABLE_CONFIG")"\nstatus=$?\nset -e\nexpected='{\"ok\":false,\"errorCount\":1,\"warningCount\":0,\"errors\":[\"unknown config table [mystery]\"],\"warnings\":[]}'\nif [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then\n  printf 'Unknown config table must fail closed.\\nExpected: %s\\nActual: %s\\n' "$expected" "$actual" >&2\n  exit 1\nfi\n\n`;
tests = replaceOnce(tests, testsAnchor, strictCases + testsAnchor, 'strict config audit tests');
fs.writeFileSync(testsPath, tests);

console.log(`DEN-1799 strict config audit applied; synchronized ${synchronized} parser copies`);
