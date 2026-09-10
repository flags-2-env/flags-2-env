#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLI="${F2E_TEST_CLI:-$ROOT_DIR/build/flags2env}"
FIXTURE_DIR="$ROOT_DIR/tests/downstream-shared-auth-cli"
CONTRACT="$FIXTURE_DIR/.cli-flags.toml"

assert_json() {
  local label="$1"
  local expected_command="$2"
  local expected_api="$3"
  local expected_json="$4"
  local expected_help="$5"
  local expected_config="$6"
  local actual="$7"

  LABEL="$label" \
  EXPECTED_COMMAND="$expected_command" \
  EXPECTED_API="$expected_api" \
  EXPECTED_JSON="$expected_json" \
  EXPECTED_HELP="$expected_help" \
  EXPECTED_CONFIG="$expected_config" \
  ACTUAL="$actual" \
    python3 - <<'PY'
import json
import os

label = os.environ["LABEL"]
actual = json.loads(os.environ["ACTUAL"])
expected = {
    "SHARED_AUTH_COMMAND": os.environ["EXPECTED_COMMAND"],
    "SHARED_AUTH_API_BASE": os.environ["EXPECTED_API"],
    "SHARED_AUTH_JSON": os.environ["EXPECTED_JSON"],
    "SHARED_AUTH_HELP": os.environ["EXPECTED_HELP"],
}
config = os.environ["EXPECTED_CONFIG"]
if config:
    expected["SHARED_AUTH_CONFIG"] = config

for key, value in expected.items():
    if actual.get(key) != value:
        raise SystemExit(
            f"{label}: expected {key}={value!r}, found {actual.get(key)!r}; full={actual!r}"
        )
if not config and "SHARED_AUTH_CONFIG" in actual:
    raise SystemExit(f"{label}: config path should be absent; full={actual!r}")
PY
}

# Build-time consumers call the same native audit. This is the first gate: the
# mirrored downstream contract must contain no unknown table/key and no type,
# alias, env, command, or collision error.
audit="$($CLI audit "$CONTRACT")"
AUDIT="$audit" python3 - <<'PY'
import json
import os
report = json.loads(os.environ["AUDIT"])
if report.get("ok") is not True or report.get("errorCount") != 0:
    raise SystemExit(f"Shared Auth CLI contract audit failed: {report!r}")
PY

actual="$(cd "$FIXTURE_DIR" && "$CLI" shared-auth health --json)"
assert_json \
  "health/json" \
  "health" \
  "http://127.0.0.1:8080" \
  "true" \
  "false" \
  "" \
  "$actual"

actual="$(cd "$FIXTURE_DIR" && "$CLI" shared-auth status --no-json --api-base=https://auth.example.test)"
assert_json \
  "status/negation" \
  "status" \
  "https://auth.example.test" \
  "false" \
  "false" \
  "" \
  "$actual"

actual="$(cd "$FIXTURE_DIR" && "$CLI" shared-auth help -h --config=./tenant.shared-auth.toml)"
assert_json \
  "help/config" \
  "help" \
  "http://127.0.0.1:8080" \
  "false" \
  "true" \
  "./tenant.shared-auth.toml" \
  "$actual"

printf 'Shared Auth CLI downstream flags contract passed\n'
