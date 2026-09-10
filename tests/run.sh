#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# F2E_TEST_CLI points the suite at an alternate build, e.g. a sanitizer one
CLI="${F2E_TEST_CLI:-$ROOT_DIR/build/flags2env}"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures"
TMP_TEST_DIR="${TMPDIR:-/tmp}/flags2env-tests-$$"
rm -rf "$TMP_TEST_DIR"
mkdir -p "$TMP_TEST_DIR"

MATERIALIZED_DOTENV_DIRS="
tests/dotenv
tests/env-audit
tests/dotenv-order
tests/env-audit-drift
tests/env-audit-clean
tests/env-audit-ignore
tests/dotenv-global-override
tests/doctor-findings
tests/dotenv-files
"

cleanup_test_state() {
  rm -rf "$TMP_TEST_DIR"
  for fixture_dir in $MATERIALIZED_DOTENV_DIRS; do
    rm -f "$ROOT_DIR/$fixture_dir/.env"
  done
  rm -f "$ROOT_DIR/tests/dotenv-files/.env.local"
}
trap cleanup_test_state EXIT
trap 'cleanup_test_state; exit 130' HUP INT TERM

# The repository never tracks plaintext .env files. Tests that exercise
# implicit ./.env discovery materialize synthetic fixtures for the
# duration of the suite and remove them on every normal/catchable exit.
for fixture_dir in $MATERIALIZED_DOTENV_DIRS; do
  cp "$ROOT_DIR/$fixture_dir/fixture.dotenv" "$ROOT_DIR/$fixture_dir/.env"
done
cp "$ROOT_DIR/tests/dotenv-files/fixture.local.dotenv" \
  "$ROOT_DIR/tests/dotenv-files/.env.local"

run_case() {
  expected="$1"
  shift
  actual="$(cd "$FIXTURE_DIR" && "$CLI" "$@")"
  if [ "$actual" != "$expected" ]; then
    printf 'Expected: %s\nActual:   %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

run_config_case() {
  config_dir="$1"
  expected="$2"
  shift 2
  actual="$(cd "$config_dir" && "$CLI" "$@")"
  if [ "$actual" != "$expected" ]; then
    printf 'Config:   %s\nExpected: %s\nActual:   %s\n' "$config_dir" "$expected" "$actual" >&2
    exit 1
  fi
}

run_case '{"PORT":"8080","DEBUG":"true","COLOR":"true","HOST":"127.0.0.1","VERBOSE":"true","NODE_ENV":"production"}' app --port 8080 --debug --host 127.0.0.1 -v -mproduction
run_case '{"PORT":"9000","DEBUG":"false","COLOR":"false"}' app -p 9000 --no-color
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --unknown value positional
run_case '{"PORT":"8181","DEBUG":"true","COLOR":"true"}' app exec --port 8181 --debug
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true"}' app --port --debug
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --port --unknown
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --port x
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --port=x
run_case '{"PORT":"-1","DEBUG":"false","COLOR":"true"}' app --port -1
run_case '{"PORT":"+7","DEBUG":"false","COLOR":"true"}' app --port +7
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --no-port=8181
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","HOST":"-internal"}' app --host=-internal
run_case '{"PORT":"4000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dv --listen-port=4000
# getopt-style short bundles: boolean-only groups ("ls -la", "rm -rf") and
# groups ending in one value-taking flag ("set -eo pipefail", "git commit -am").
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dv
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -vd
run_case '{"PORT":"8080","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dvp 8080
run_case '{"PORT":"8080","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dvp8080
run_case '{"PORT":"8080","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dvp=8080
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true","NODE_ENV":"production"}' app -dvm production
# the value flag ends the bundle: later characters are its value, never flags
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","NODE_ENV":"vc"}' app -dmvc
# Exact real-world bundle shapes from the public docs.
run_config_case "$ROOT_DIR/tests/short-bundles" '{"LONG":"true","ALL":"true"}' app -la
run_config_case "$ROOT_DIR/tests/short-bundles" '{"RECURSIVE":"true","FORCE":"true"}' app -rf
run_config_case "$ROOT_DIR/tests/short-bundles" '{"ERREXIT":"true","SHELL_OPTION":"pipefail"}' app -eo pipefail
run_config_case "$ROOT_DIR/tests/short-bundles" '{"ERREXIT":"true","SHELL_OPTION":"pipefail"}' app -eo=pipefail
# "tar -xvf archive.tar" shape: several leading bools, then a value flag
run_config_case "$ROOT_DIR/tests/short-bundles" '{"LONG":"true","ALL":"true","RECURSIVE":"true","FORCE":"true"}' app -larf
run_config_case "$ROOT_DIR/tests/short-bundles" '{"LONG":"true","ALL":"true","ERREXIT":"true","SHELL_OPTION":"pipefail"}' app -laeo pipefail
# ...and an all-bool bundle never mistakes a following word for a value: -lae
# ends in a bool, so "pipefail" stays a positional
run_config_case "$ROOT_DIR/tests/short-bundles" '{"LONG":"true","ALL":"true","ERREXIT":"true"}' app -lae pipefail
# The trailing bool of an all-bool bundle consumes a separated boolean value,
# exactly as the lone spelling does. This is why "rm -rf false" sets FORCE
# false rather than treating "false" as a filename - identical to "rm -r -f
# false" today, and suppressed by require_equals (see the equals-only cases).
run_config_case "$ROOT_DIR/tests/short-bundles" '{"RECURSIVE":"true","FORCE":"false"}' app -rf false
run_config_case "$ROOT_DIR/tests/short-bundles" '{"RECURSIVE":"true","FORCE":"false"}' app -r -f false
run_config_case "$ROOT_DIR/tests/short-bundles" '{"RECURSIVE":"true","FORCE":"true"}' app -rf archive.tar
# Node accepts -pe (print + eval); the value-taking -e must end the bundle.
run_config_case "$ROOT_DIR/tests/node-short-bundle" '{"PRINT":"true","EVAL":""}' app -pe ''
run_config_case "$ROOT_DIR/tests/node-short-bundle" '{"PRINT":"true","EVAL":"1 + 1"}' app -pe '1 + 1'
# ...and the reversed spelling stays getopt: -e takes a value, so "p" is that
# value and the script that follows is positional. Same declaration, different
# order, different meaning - which is the point of putting the value flag last.
run_config_case "$ROOT_DIR/tests/node-short-bundle" '{"EVAL":"p"}' app -ep '1 + 1'
# The literal tar letters, as the muscle memory spells them.
TAR_DIR="$ROOT_DIR/tests/tar-short-bundle"
run_config_case "$TAR_DIR" '{"EXTRACT":"true","VERBOSE":"true","FILE":"archive.tar"}' app -xvf archive.tar
run_config_case "$TAR_DIR" '{"EXTRACT":"true","VERBOSE":"true","FILE":"archive.tar"}' app -xvfarchive.tar
run_config_case "$TAR_DIR" '{"EXTRACT":"true","VERBOSE":"true","FILE":"archive.tar"}' app -xvf=archive.tar
run_config_case "$TAR_DIR" '{"EXTRACT":"true","GZIP":"true","VERBOSE":"true","FILE":"archive.tgz"}' app -xzvf archive.tgz
run_config_case "$TAR_DIR" '{"EXTRACT":"true","VERBOSE":"true","FILE":"archive.tar"}' app -x -v -f archive.tar
# a suffix that reads as a boolean value for the first flag keeps that meaning
# (compatibility): -dt is debug=true via true_aliases, never a bundle
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true"}' app -dt
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app -df
# an undeclared character anywhere in the token means it is not a bundle
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app -dvz
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app -zdv
# a bundle whose value flag is last but has no consumable value sets the
# booleans and leaves the value flag untouched, like a bare -p would
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dvp
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dvp --debug

# A bundle is shorthand for the same shorts written separately, so `-dv` must
# mean exactly `-d -v` - including for the trailing short, the only one
# adjacent to the next argv element and so the only one that can consume a
# separated boolean value. Each pair below asserts that equivalence directly.
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"false"}' app -dv false
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"false"}' app -d -v false
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","VERBOSE":"true"}' app -vd false
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","VERBOSE":"true"}' app -v -d false
# only a value the trailing flag would itself accept is consumed: "0" is a
# false_alias of -d, never of -v, so it stays a positional either way
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dv 0
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -d -v 0
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","VERBOSE":"true"}' app -vd 0
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","VERBOSE":"true"}' app -v -d 0
# a non-boolean word is never consumed by a bundle's trailing bool
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dv notabool
# a repeated short is still just its last occurrence, and the trailing one
# still owns the separated value
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","VERBOSE":"false"}' app -vv false
# an explicit "=" makes an empty remainder a real assignment, so every
# spelling of "set this to the empty string" agrees
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","NODE_ENV":""}' app --mode=
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","NODE_ENV":""}' app -m=
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true","NODE_ENV":""}' app -dvm=
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true","HOST":""}' app -h=
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true","HOST":""}' app -dvh=
# an empty remainder with no "=" is still not a value: -dvm alone leaves the
# value flag untouched rather than setting it to ""
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true","VERBOSE":"true"}' app -dvm
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true"}' app --debug=t
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --debug false
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --debug 0
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --debug=f
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app -d1 -d0
run_case '{"PORT":"3000","DEBUG":"true","COLOR":"true"}' app -d=1
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --color=0
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"false"}' app --color=false
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --debug=1 --debug=0
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --debug=t --debug=f
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app --color=1
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app -v0
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app -- --port 9999 --debug
run_case '{"PORT":"3000","DEBUG":"false","COLOR":"true"}' app -- --help

actual="$(cd "$ROOT_DIR/tests/equals-only" && FLAGS2ENV_ALLOW_UNKNOWN=1 "$CLI" app --future value)"
expected="{\"PORT\":\"3000\",\"DEBUG\":\"false\",\"F2E_POSITIONALS\":\"[\\\"$CLI\\\",\\\"app\\\",\\\"value\\\"]\"}"
if [ "$actual" != "$expected" ]; then
  printf 'Expected env allow-unknown parse: %s\nActual:                           %s\n' "$expected" "$actual" >&2
  exit 1
fi

# require_equals applies inside mixed short bundles exactly as it does to a
# lone short flag: inline values pass, a separated value stays positional
actual="$(cd "$ROOT_DIR/tests/equals-only" && "$CLI" app -dp=8080)"
expected="{\"PORT\":\"8080\",\"DEBUG\":\"true\",\"F2E_POSITIONALS\":\"[\\\"$CLI\\\",\\\"app\\\"]\"}"
if [ "$actual" != "$expected" ]; then
  printf 'Expected equals-only bundle parse: %s\nActual:                           %s\n' "$expected" "$actual" >&2
  exit 1
fi
actual="$(cd "$ROOT_DIR/tests/equals-only" && "$CLI" app -dp 8080)"
expected="{\"PORT\":\"3000\",\"DEBUG\":\"true\",\"F2E_POSITIONALS\":\"[\\\"$CLI\\\",\\\"app\\\",\\\"8080\\\"]\"}"
if [ "$actual" != "$expected" ]; then
  printf 'Expected equals-only bundle to leave separated value positional: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

# require_equals also suppresses the trailing bool's separated value, so a
# bundle and its separated spelling stay equivalent under that setting too
actual="$(cd "$ROOT_DIR/tests/equals-only" && "$CLI" app -d false)"
expected="{\"PORT\":\"3000\",\"DEBUG\":\"true\",\"F2E_POSITIONALS\":\"[\\\"$CLI\\\",\\\"app\\\",\\\"false\\\"]\"}"
if [ "$actual" != "$expected" ]; then
  printf 'Expected equals-only lone bool to leave separated value positional: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

# An undeclared character in a bundle-shaped token must be reported no matter
# where it sits. Reporting used to depend on position: "-zd" failed the
# token[1] lookup and was recorded, while "-dz" reached the parser's fallback
# and vanished with no entry in any channel - the exact shape of a typo like
# "rm -rF".
for bundle_unknown in -zd -dz -dvz -zdv; do
  actual="$(cd "$ROOT_DIR/tests/equals-only" && "$CLI" app "$bundle_unknown")"
  expected="{\"PORT\":\"3000\",\"DEBUG\":\"false\",\"F2E_POSITIONALS\":\"[\\\"$CLI\\\",\\\"app\\\"]\",\"F2E_UNKNOWN_OPTIONS\":\"[\\\"$bundle_unknown\\\"]\"}"
  if [ "$actual" != "$expected" ]; then
    printf 'Expected %s to be reported as an unknown option: %s\nActual: %s\n' "$bundle_unknown" "$expected" "$actual" >&2
    exit 1
  fi
done

# The error channel names the character that is actually at fault. The old
# fallback reported `flags.debug value "vz" is not a valid bool` - a flag that
# is fine and a value nobody typed - which sent people looking in the wrong
# place for a mistyped bundle.
FAULT_DIR="$ROOT_DIR/tests/short-bundle-faults"
run_config_case "$FAULT_DIR" '{"POSITIONALS":"[\"'"$CLI"'\",\"app\"]","UNKNOWN":"[\"-dvz\"]","ERRORS":"[\"\\\"-dvz\\\" is not a short flag bundle: -z is not a declared short flag\"]"}' app -dvz
run_config_case "$FAULT_DIR" '{"POSITIONALS":"[\"'"$CLI"'\",\"app\"]","UNKNOWN":"[\"-dzv\"]","ERRORS":"[\"\\\"-dzv\\\" is not a short flag bundle: -z is not a declared short flag\"]"}' app -dzv
# The same explanation regardless of where the bad character sits - that
# symmetry is the whole point.
run_config_case "$FAULT_DIR" '{"POSITIONALS":"[\"'"$CLI"'\",\"app\"]","UNKNOWN":"[\"-zdv\"]","ERRORS":"[\"\\\"-zdv\\\" is not a short flag bundle: -z is not a declared short flag\"]"}' app -zdv
# A lone unrecognized short is just an unknown option; there is nothing about
# a bundle to explain.
run_config_case "$FAULT_DIR" '{"POSITIONALS":"[\"'"$CLI"'\",\"app\"]","UNKNOWN":"[\"-q\"]"}' app -q
# allow_unknown silences both channels, as it does for any unknown option.
run_config_case "$FAULT_DIR" '{"POSITIONALS":"[\"'"$CLI"'\",\"app\"]"}' app --allow-unknown -dvz
# An invalid *value* is still reported against the flag that owns it.
run_config_case "$FAULT_DIR" '{"DEBUG":"true","VERBOSE":"true","POSITIONALS":"[\"'"$CLI"'\",\"app\"]","ERRORS":"[\"flags.port value \\\"abc\\\" is not a valid integer\"]"}' app -dvpabc

# ...but a character that is a *value* for the bundle's value-taking flag is
# not an unknown option: "z" is -p's (invalid) value, reported through the
# error channel instead, and the leading bools still apply
actual="$(cd "$ROOT_DIR/tests/equals-only" && "$CLI" app -dpz)"
expected="{\"PORT\":\"3000\",\"DEBUG\":\"true\",\"F2E_POSITIONALS\":\"[\\\"$CLI\\\",\\\"app\\\"]\"}"
if [ "$actual" != "$expected" ]; then
  printf 'Expected mixed-bundle invalid value not to report an unknown option: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$(cd "$ROOT_DIR" && "$CLI" app --allow-unknown --future)"
expected='{"FLAGS2ENV_ALLOW_UNKNOWN":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected root allow-unknown parse: %s\nActual:                           %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$("$CLI" shell-env --config "$FIXTURE_DIR/.cli-flags.toml" -- app --debug=t --port 8181 --host "it's-local")"
for expected_export in "export PORT='8181'" "export DEBUG='true'" "export COLOR='true'" "export HOST='it'\\''s-local'"; do
  case "$actual" in
    *"$expected_export"*)
      ;;
    *)
      printf 'Unexpected shell env output; missing %s:\n%s\n' "$expected_export" "$actual" >&2
      exit 1
      ;;
  esac
done

FLAGS2ENV_BIN="$CLI" FLAGS2ENV_CONFIG="$FIXTURE_DIR/.cli-flags.toml" bash "$ROOT_DIR/clients/bash/test.bash"
if command -v zsh >/dev/null 2>&1; then
  FLAGS2ENV_BIN="$CLI" FLAGS2ENV_CONFIG="$FIXTURE_DIR/.cli-flags.toml" zsh "$ROOT_DIR/clients/zsh/test.zsh"
fi

wide_help="$(cd "$FIXTURE_DIR" && COLUMNS=132 "$CLI" app --help)"
case "$wide_help" in
  *'| Option(s)'*'| Env'*'| Type'*'| Default'*'| Description'*'TCP port for the app listener.'*'More help: https://example.com/flags2env/help'*)
    ;;
  *)
    printf 'Unexpected wide help table:\n%s\n' "$wide_help" >&2
    exit 1
    ;;
esac
case "$wide_help" in
  *'{"PORT"'*)
    printf 'Help should print a table, not JSON:\n%s\n' "$wide_help" >&2
    exit 1
    ;;
esac

narrow_help="$(cd "$FIXTURE_DIR" && COLUMNS=70 "$CLI" app --help)"
case "$narrow_help" in
  *'| Option(s)'*'| Details'*'env=PORT; type=integer; default=3000'*'More help: https://example.com/flags2env/help'*)
    ;;
  *)
    printf 'Unexpected narrow help table:\n%s\n' "$narrow_help" >&2
    exit 1
    ;;
esac
case "$narrow_help" in
  *'| Env'*|*'| Description'*)
    printf 'Narrow help should use fewer columns:\n%s\n' "$narrow_help" >&2
    exit 1
    ;;
esac

custom_help="$(cd "$ROOT_DIR/tests/table-options" && COLUMNS=132 "$CLI" app --help)"
case "$custom_help" in
  *'| Option(s)'*'| Description'*'TCP port for the app listener.'*)
    ;;
  *)
    printf 'Unexpected custom help table:\n%s\n' "$custom_help" >&2
    exit 1
    ;;
esac
case "$custom_help" in
  *'| Env'*|*'| Type'*|*'| Default'*)
    printf 'Custom help should omit unselected/excluded columns:\n%s\n' "$custom_help" >&2
    exit 1
    ;;
esac

actual="$(cd "$ROOT_DIR" && "$CLI" app --config .cli-flags.toml --native-lib ./build/libflags2env.so --node-addon ./clients/nodejs/build/Release/flags2env.node --runtime nodejs --audit=t)"
expected='{"FLAGS2ENV_CONFIG":".cli-flags.toml","FLAGS2ENV_NATIVE_LIB":"./build/libflags2env.so","FLAGS2ENV_NODE_ADDON":"./clients/nodejs/build/Release/flags2env.node","FLAGS2ENV_RUNTIME":"nodejs","FLAGS2ENV_AUDIT":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected root config parse: %s\nActual:                     %s\n' "$expected" "$actual" >&2
  exit 1
fi

case "$actual" in
  *PORT*|*NODE_ENV*)
    printf 'Root config should not parse app env names: %s\n' "$actual" >&2
    exit 1
    ;;
esac

actual="$(cd "$ROOT_DIR" && "$CLI" audit)"
expected='{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected root config audit: %s\nActual:                     %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$(cd "$FIXTURE_DIR/nested/deeper" && "$CLI" audit)"
expected='{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected clean audit: %s\nActual:               %s\n' "$expected" "$actual" >&2
  exit 1
fi

NATIVE_SCALARS_DIR="$ROOT_DIR/tests/native-scalars"
actual="$(cd "$NATIVE_SCALARS_DIR" && "$CLI" app)"
expected='{"PORT":"3000","DEBUG":"false","PAYLOAD":"7"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected native scalar defaults: %s\nActual:                          %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$(cd "$NATIVE_SCALARS_DIR" && "$CLI" app --debug 1 --payload true --port +12)"
expected='{"PORT":"+12","DEBUG":"true","PAYLOAD":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected native scalar overrides: %s\nActual:                           %s\n' "$expected" "$actual" >&2
  exit 1
fi

# a mixed bundle's invalid trailing value reports against the value-taking
# flag through errors_env while the leading booleans still apply
actual="$(cd "$NATIVE_SCALARS_DIR" && "$CLI" app -dpx)"
expected='{"PORT":"3000","DEBUG":"true","PAYLOAD":"7","F2E_PARSE_ERRORS":"[\"flags.port value \\\"x\\\" is not a valid integer\"]"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected mixed bundle error report: %s\nActual:                             %s\n' "$expected" "$actual" >&2
  exit 1
fi

# typed bundle values ride the same validation as their long spellings: a
# json-typed value flag consumes a separated bundle value, and a typed
# negative number is accepted in separated form
actual="$(cd "$NATIVE_SCALARS_DIR" && "$CLI" app -dj '{"a":1}')"
expected='{"PORT":"3000","DEBUG":"true","PAYLOAD":"{\"a\":1}"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected mixed bundle json value: %s\nActual:                           %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$(cd "$NATIVE_SCALARS_DIR" && "$CLI" app -dp -1)"
expected='{"PORT":"-1","DEBUG":"true","PAYLOAD":"7"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected mixed bundle negative int: %s\nActual:                             %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$("$CLI" audit env "$ROOT_DIR/tests/env-audit-clean/.cli-flags.toml" "$ROOT_DIR/tests/env-audit-clean/.env")"
expected='{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected clean env audit: %s\nActual:                   %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$("$CLI" audit env "$ROOT_DIR/tests/env-audit-ignore/.cli-flags.toml" "$ROOT_DIR/tests/env-audit-ignore/.env")"
expected='{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected ignored env audit: %s\nActual:                     %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$("$ROOT_DIR/scripts/audit-changed-cli-flags.sh" "tests/env-audit-ignore/.cli-flags.toml")"
case "$actual" in
  *'cli-flags audit: tests/env-audit-ignore/.cli-flags.toml'*'cli-flags env audit: tests/env-audit-ignore/.env'*'{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'*)
    ;;
  *)
    printf 'Expected changed-config helper to run ignored env audit:\n%s\n' "$actual" >&2
    exit 1
    ;;
esac

actual="$("$ROOT_DIR/scripts/audit-changed-cli-flags.sh" "tests/env-audit-ignore/.env")"
case "$actual" in
  *'cli-flags audit: tests/env-audit-ignore/.cli-flags.toml'*'cli-flags env audit: tests/env-audit-ignore/.env'*'{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'*)
    ;;
  *)
    printf 'Expected changed-env helper to run adjacent config audit:\n%s\n' "$actual" >&2
    exit 1
    ;;
esac

actual="$("$ROOT_DIR/scripts/audit-changed-cli-flags.sh" \
  "tests/audit-invalid-subcommand-nesting/.cli-flags.toml" \
  "tests/env-audit-drift/.env")"
case "$actual" in
  *'cli-flags audit: skipping expected-negative fixture tests/audit-invalid-subcommand-nesting/.cli-flags.toml'*)
    ;;
  *)
    printf 'Expected changed-config helper to skip negative fixtures:\n%s\n' "$actual" >&2
    exit 1
    ;;
esac
case "$actual" in
  *'cli-flags audit: skipping expected-negative fixture tests/env-audit-drift/.cli-flags.toml'*)
    ;;
  *)
    printf 'Expected changed-env helper to skip negative fixtures:\n%s\n' "$actual" >&2
    exit 1
    ;;
esac

set +e
actual="$("$CLI" audit env "$ROOT_DIR/tests/env-audit-drift/.cli-flags.toml" "$ROOT_DIR/tests/env-audit-drift/.env")"
status=$?
set -e
expected='{"ok":false,"errorCount":1,"warningCount":4,"errors":[".env key \"EXTRA\" is not declared by .cli-flags.toml"],"warnings":[".env key \"DEBUG\" appears more than once",".env line 5 has invalid key \"BAD-KEY\"",".cli-flags.toml env \"HOST\" is not present in .env",".cli-flags.toml env \"VERBOSE\" is not present in .env"]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected failing env audit status and report:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

completion_bash="$("$CLI" completion bash mycli "$FIXTURE_DIR/.cli-flags.toml")"
case "$completion_bash" in
  *'_flags2env_complete_mycli()'*'--port --port= --listen-port --listen-port= -p'*'--no-debug'*'complete -o default -F _flags2env_complete_mycli -- '\''mycli'\'''*)
    ;;
  *)
    printf 'Unexpected bash completion script:\n%s\n' "$completion_bash" >&2
    exit 1
    ;;
esac

completion_zsh="$("$CLI" completion zsh mycli "$FIXTURE_DIR/.cli-flags.toml")"
case "$completion_zsh" in
  *'#compdef mycli'*'_arguments -s'*"'--port[PORT]:value:'"*"'--debug[DEBUG]::value:(true false t 1 f 0)'"*"'--no-debug[DEBUG]'"*)
    ;;
  *)
    printf 'Unexpected zsh completion script:\n%s\n' "$completion_zsh" >&2
    exit 1
    ;;
esac

completion_zsh_path="$("$CLI" completion zsh /usr/local/bin/mycli/ "$FIXTURE_DIR/.cli-flags.toml")"
case "$completion_zsh_path" in
  *'#compdef mycli'*)
    ;;
  *)
    printf 'Zsh completion should use safe command basename:\n%s\n' "$completion_zsh_path" >&2
    exit 1
    ;;
esac

CODEGEN_CONFIG="$ROOT_DIR/tests/codegen/.cli-flags.toml"
generated_typescript="$("$CLI" generate typescript "$CODEGEN_CONFIG" --name CliStuff)"
case "$generated_typescript" in
  *'export interface CliStuff'*'PORT: number;'*'NAME?: string;'*'ITEMS: unknown[];'*'LABELS: Record<string, unknown>;'*'UNTYPED: string;'*)
    ;;
  *)
    printf 'Unexpected generated TypeScript interface:\n%s\n' "$generated_typescript" >&2
    exit 1
    ;;
esac

generated_dart="$("$CLI" generate dart "$CODEGEN_CONFIG" --name CliStuff)"
case "$generated_dart" in
  *'final class CliStuff'*'final int PORT;'*'final String UNTYPED;'*'factory CliStuff.fromJson'*)
    ;;
  *)
    printf 'Unexpected generated Dart class:\n%s\n' "$generated_dart" >&2
    exit 1
    ;;
esac

generated_schema="$("$CLI" generate json-schema --config "$CODEGEN_CONFIG" --name CliStuff)"
case "$generated_schema" in
  *'"title": "CliStuff"'*'"RATIO": {"type":"number"'*'"ITEMS": {"type":"array"'*'"LABELS": {"type":"object"'*)
    ;;
  *)
    printf 'Unexpected generated JSON Schema:\n%s\n' "$generated_schema" >&2
    exit 1
    ;;
esac

OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/f2e-gen-out.XXXXXX")"
OUTPUT_DART="$OUTPUT_DIR/generated/dart/env.dart"
OUTPUT_SCHEMA="$OUTPUT_DIR/generated/json-schema/env.schema.json"
"$CLI" generate dart "$CODEGEN_CONFIG" --name CliStuff --output "$OUTPUT_DART"
"$CLI" generate json-schema "$CODEGEN_CONFIG" --name CliStuff --output "$OUTPUT_SCHEMA"
if [ -w "$OUTPUT_DART" ] || [ -w "$OUTPUT_SCHEMA" ]; then
  printf 'generate --output must chmod a-w the written files\n' >&2
  rm -rf "$OUTPUT_DIR"
  exit 1
fi
if ! grep -q 'final class CliStuff' "$OUTPUT_DART"; then
  printf 'generate --output dart file missing class:\n%s\n' "$(cat "$OUTPUT_DART")" >&2
  rm -rf "$OUTPUT_DIR"
  exit 1
fi
python3 "$ROOT_DIR/scripts/check-generated-contract.py" --self-test
python3 "$ROOT_DIR/scripts/check-generated-contract.py" --root "$ROOT_DIR" --freeze --require-readonly
rm -rf "$OUTPUT_DIR"

set +e
"$CLI" generate unsupported "$CODEGEN_CONFIG" >/dev/null 2>/dev/null
status=$?
set -e
if [ "$status" -eq 0 ]; then
  printf 'Unsupported codegen language should fail\n' >&2
  exit 1
fi

set +e
"$CLI" completion bash / "$FIXTURE_DIR/.cli-flags.toml" >/dev/null 2>/dev/null
status=$?
set -e
if [ "$status" -eq 0 ]; then
  printf 'Slash-only completion command name should fail\n' >&2
  exit 1
fi

set +e
"$CLI" completion bash 'bad;name' "$FIXTURE_DIR/.cli-flags.toml" >/dev/null 2>/dev/null
status=$?
set -e
if [ "$status" -eq 0 ]; then
  printf 'Unsafe completion command name should fail\n' >&2
  exit 1
fi

UNSAFE_CONFIG="$ROOT_DIR/tests/audit-unsafe-shell/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$UNSAFE_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":5,"warningCount":0,"errors":["flags.bad env \"BAD-NAME\" is not a valid env var name","flags.bad alias \"bad alias\" contains unsafe option characters","flags.bad has invalid short flag \";\"","flags.bad true_aliases contains unsafe shell token \"bad value\"","parse.positionals_env \"BAD-POSITIONALS\" is not a valid env var name"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected unsafe config audit status and report:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

INVALID_CONFIG_OPTIONS_CONFIG="$ROOT_DIR/tests/audit-invalid-config-options/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_CONFIG_OPTIONS_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":4,"warningCount":0,"errors":["help.columns must be a list of supported table column names","help.exclude must be a list of supported table column names","env.ignore contains invalid env var name \"BAD-KEY\"","env.ignore contains invalid env var name \"\""],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected invalid config-options audit status and report:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

INVALID_CONFIG_LISTS_CONFIG="$ROOT_DIR/tests/audit-invalid-config-lists/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_CONFIG_LISTS_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":2,"warningCount":0,"errors":["help.columns must be a list of supported table column names","env.ignore must be a list of env var names"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected invalid config-list audit status and report:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

INVALID_ENV_ONLY_CONFIG="$ROOT_DIR/tests/audit-invalid-env-only/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_ENV_ONLY_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":1,"warningCount":0,"errors":["flags.bad env \"BAD-NAME\" is not a valid env var name"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected invalid env-only audit status and report:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

set +e
actual="$("$CLI" audit env "$INVALID_ENV_ONLY_CONFIG" "$ROOT_DIR/tests/env-audit/.env")"
status=$?
set -e
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected env audit to stop on invalid config:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

set +e
"$CLI" completion bash mycli "$INVALID_ENV_ONLY_CONFIG" >/dev/null 2>/dev/null
status=$?
set -e
if [ "$status" -eq 0 ]; then
  printf 'Invalid env-only config should not produce completion script\n' >&2
  exit 1
fi

UNKNOWN_KEY_CONFIG="$ROOT_DIR/tests/audit-invalid-unknown-key/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$UNKNOWN_KEY_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":1,"warningCount":0,"errors":["unknown key \"mystery\" in [flags.*]"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Unknown config key must fail closed.\nExpected: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

UNKNOWN_TABLE_CONFIG="$ROOT_DIR/tests/audit-invalid-unknown-table/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$UNKNOWN_TABLE_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":1,"warningCount":0,"errors":["unknown config table [mystery]"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Unknown config table must fail closed.\nExpected: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

INVALID_TYPE_CONFIG="$ROOT_DIR/tests/audit-invalid-type/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_TYPE_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":1,"warningCount":0,"errors":["flags.port type \"integerer\" is not supported"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected invalid type audit status and report:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

# a single-char boolean value alias that doubles as a sibling short flag makes
# "-dt" ambiguous between "value for -d" and "bundle"; the audit must say so
BUNDLE_ALIAS_DIR="$TMP_TEST_DIR/audit-bundle-alias"
mkdir -p "$BUNDLE_ALIAS_DIR"
cat > "$BUNDLE_ALIAS_DIR/.cli-flags.toml" <<'EOF'
[flags.debug]
env = "DEBUG"
aliases = ["debug"]
short = "d"
type = "bool"
true_aliases = ["t"]

[flags.trace]
env = "TRACE"
aliases = ["trace"]
short = "t"
type = "bool"
EOF
actual="$("$CLI" audit "$BUNDLE_ALIAS_DIR/.cli-flags.toml")"
expected='{"ok":true,"errorCount":0,"warningCount":1,"errors":[],"warnings":["flags.debug boolean value alias \"t\" doubles as short flag -t (flags.trace); \"-dt\" parses as a bundle, not a value for flags.debug"]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected bundle-alias shadowing warning:\n%s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi
# and the parser indeed reads the all-boolean token as a bundle
actual="$(cd "$BUNDLE_ALIAS_DIR" && "$CLI" app -dt)"
expected='{"DEBUG":"true","TRACE":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected -dt to parse as a bundle: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

# same collision against a value-taking short: the value-alias reading wins
BUNDLE_ALIAS_VALUE_DIR="$TMP_TEST_DIR/audit-bundle-alias-value"
mkdir -p "$BUNDLE_ALIAS_VALUE_DIR"
cat > "$BUNDLE_ALIAS_VALUE_DIR/.cli-flags.toml" <<'EOF'
[flags.debug]
env = "DEBUG"
aliases = ["debug"]
short = "d"
type = "bool"
true_aliases = ["t"]

[flags.tag]
env = "TAG"
aliases = ["tag"]
short = "t"
type = "string"
EOF
actual="$("$CLI" audit "$BUNDLE_ALIAS_VALUE_DIR/.cli-flags.toml")"
expected='{"ok":true,"errorCount":0,"warningCount":1,"errors":[],"warnings":["flags.debug boolean value alias \"t\" doubles as short flag -t (flags.tag); \"-dt\" parses as a value for flags.debug, not a bundle"]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected bundle-alias value shadowing warning:\n%s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi
actual="$(cd "$BUNDLE_ALIAS_VALUE_DIR" && "$CLI" app -dt)"
expected='{"DEBUG":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected -dt to stay a boolean value: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

# Reachability is scope-sensitive: a global boolean alias can collide with a
# short flag introduced by an active child command, and audit must not miss it.
SCOPED_BUNDLE_ALIAS_CONFIG="$ROOT_DIR/tests/audit-bundle-command/.cli-flags.toml"
actual="$("$CLI" audit "$SCOPED_BUNDLE_ALIAS_CONFIG")"
expected='{"ok":true,"errorCount":0,"warningCount":1,"errors":[],"warnings":["flags.debug boolean value alias \"t\" doubles as short flag -t (flags.trace) when command \"commit\" is active or when no command is selected; \"-dt\" parses as a bundle, not a value for flags.debug"]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected command-scope bundle-alias warning:\n%s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi
run_config_case "$ROOT_DIR/tests/audit-bundle-command" '{"FLAGS2ENV_COMMAND":"commit","DEBUG":"true","TRACE":"true"}' gitish commit -dt
run_config_case "$ROOT_DIR/tests/audit-bundle-command" '{"FLAGS2ENV_COMMAND":"","DEBUG":"true","TRACE":"true"}' gitish -dt

# A short flag is one character; everything past the first byte used to be
# dropped in silence, shipping a CLI whose "-ab" was a bundle rather than the
# two-letter flag the author wrote.
MULTI_SHORT_DIR="$TMP_TEST_DIR/audit-multi-char-short"
mkdir -p "$MULTI_SHORT_DIR"
cat > "$MULTI_SHORT_DIR/.cli-flags.toml" <<'EOF'
[flags.alpha]
env = "ALPHA"
aliases = ["alpha"]
short = "ab"
type = "bool"

[flags.beta]
env = "BETA"
aliases = ["beta"]
short = "b"
type = "bool"
EOF
set +e
actual="$("$CLI" audit "$MULTI_SHORT_DIR/.cli-flags.toml")"
set -e
expected='{"ok":false,"errorCount":1,"warningCount":0,"errors":["flags.alpha short \"ab\" is more than one character; only \"a\" is used, and \"-ab\" parses as a short flag bundle"],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected multi-character short error:\n%s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi
# and the parse the author did not ask for is exactly the bundle
actual="$(cd "$MULTI_SHORT_DIR" && "$CLI" app -ab)"
expected='{"ALPHA":"true","BETA":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected -ab to parse as a bundle: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

# A multi-character boolean value alias can spell a whole bundle, and then two
# spellings that differ only in whether a value is inline resolve to different
# flags. The audit has to say so.
MULTI_ALIAS_DIR="$TMP_TEST_DIR/audit-multi-char-alias"
mkdir -p "$MULTI_ALIAS_DIR"
cat > "$MULTI_ALIAS_DIR/.cli-flags.toml" <<'EOF'
[flags.debug]
env = "DEBUG"
aliases = ["debug"]
short = "d"
type = "bool"
true_aliases = ["vp"]

[flags.verbose]
env = "VERBOSE"
aliases = ["verbose"]
short = "v"
type = "bool"

[flags.port]
env = "PORT"
aliases = ["port"]
short = "p"
type = "integer"
EOF
actual="$("$CLI" audit "$MULTI_ALIAS_DIR/.cli-flags.toml")"
expected='{"ok":true,"errorCount":0,"warningCount":1,"errors":[],"warnings":["flags.debug boolean value alias \"vp\" also spells a short flag bundle; \"-dvp\" is a value for flags.debug, but \"-dvp\" followed by anything parses as a bundle"]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected multi-character alias bundle warning:\n%s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi
actual="$(cd "$MULTI_ALIAS_DIR" && "$CLI" app -dvp)"
expected='{"DEBUG":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected -dvp to stay a boolean value: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi
actual="$(cd "$MULTI_ALIAS_DIR" && "$CLI" app -dvp8080)"
expected='{"DEBUG":"true","VERBOSE":"true","PORT":"8080"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected -dvp8080 to parse as a bundle: %s\nActual: %s\n' "$expected" "$actual" >&2
  exit 1
fi

set +e
"$CLI" completion bash mycli "$UNSAFE_CONFIG" >/dev/null 2>/dev/null
status=$?
set -e
if [ "$status" -eq 0 ]; then
  printf 'Unsafe config should not produce completion script\n' >&2
  exit 1
fi

F2E_COMPLETION_DIR="$TMP_TEST_DIR/bash-completions" \
F2E_BASHRC="$TMP_TEST_DIR/bashrc" \
  "$CLI" completion install bash mycli "$FIXTURE_DIR/.cli-flags.toml" >/dev/null
F2E_COMPLETION_DIR="$TMP_TEST_DIR/bash-completions" \
F2E_BASHRC="$TMP_TEST_DIR/bashrc" \
  "$CLI" completion install bash mycli "$FIXTURE_DIR/.cli-flags.toml" >/dev/null
if [ ! -f "$TMP_TEST_DIR/bash-completions/mycli" ] ||
   ! grep -q '_flags2env_complete_mycli' "$TMP_TEST_DIR/bash-completions/mycli" ||
   ! grep -q 'flags2env completion: bash mycli' "$TMP_TEST_DIR/bashrc"; then
  printf 'Bash completion install did not write expected files under %s\n' "$TMP_TEST_DIR" >&2
  exit 1
fi
if [ "$(grep -c 'flags2env completion: bash mycli' "$TMP_TEST_DIR/bashrc")" -ne 1 ]; then
  printf 'Bash completion install should be idempotent under %s\n' "$TMP_TEST_DIR" >&2
  exit 1
fi

F2E_COMPLETION_DIR="$TMP_TEST_DIR/path-bash-completions" \
F2E_BASHRC="$TMP_TEST_DIR/path-bashrc" \
  "$CLI" completion install bash /usr/local/bin/mycli/ "$FIXTURE_DIR/.cli-flags.toml" >/dev/null
if [ ! -f "$TMP_TEST_DIR/path-bash-completions/mycli" ] ||
   ! grep -q "complete -o default -F _flags2env_complete_mycli -- 'mycli'" "$TMP_TEST_DIR/path-bash-completions/mycli" ||
   ! grep -q 'flags2env completion: bash mycli' "$TMP_TEST_DIR/path-bashrc"; then
  printf 'Bash completion install should use safe path basename under %s\n' "$TMP_TEST_DIR" >&2
  exit 1
fi

F2E_COMPLETION_DIR="$TMP_TEST_DIR/zsh-completions" \
F2E_ZSHRC="$TMP_TEST_DIR/zshrc" \
  "$CLI" completion install zsh mycli "$FIXTURE_DIR/.cli-flags.toml" >/dev/null
if [ ! -f "$TMP_TEST_DIR/zsh-completions/_mycli" ] ||
   ! grep -q '#compdef mycli' "$TMP_TEST_DIR/zsh-completions/_mycli" ||
   ! grep -q 'flags2env completion: zsh mycli' "$TMP_TEST_DIR/zshrc"; then
  printf 'Zsh completion install did not write expected files under %s\n' "$TMP_TEST_DIR" >&2
  exit 1
fi

INVALID_CONFIG="$ROOT_DIR/tests/audit-invalid/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":6,"warningCount":1,"errors":["flags.debug true_aliases contains canonical false","flags.debug value alias \"t\" appears in both true_aliases and false_aliases","alias \"no-debug\" clashes with negated bool flag flags.debug","flags.debug and flags.trace both map to env \"DEBUG\"","flags.debug and flags.trace both use short flag \"d\"","flags.debug and flags.trace both use alias \"debug\""],"warnings":["flags.trace declares boolean value aliases but type is not bool"]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected failing audit status and report:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

actual="$(cd "$FIXTURE_DIR/nested/deeper" && "$CLI" app --debug=t)"
expected='{"PORT":"3000","DEBUG":"true","COLOR":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected upward search: %s\nActual:                 %s\n' "$expected" "$actual" >&2
  exit 1
fi

HOME_FIXTURE="$ROOT_DIR/tests/home-with-config"
actual="$(cd "$HOME_FIXTURE" && HOME="$HOME_FIXTURE" "$CLI" app --bad)"
expected='{}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected HOME refusal: %s\nActual:                %s\n' "$expected" "$actual" >&2
  exit 1
fi

SUBCOMMANDS_DIR="$ROOT_DIR/tests/subcommands"
run_subcommand_case() {
  expected="$1"
  shift
  actual="$(cd "$SUBCOMMANDS_DIR" && "$CLI" "$@")"
  if [ "$actual" != "$expected" ]; then
    printf 'Expected subcommand parse: %s\nActual:                    %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

BASE_POSITIONALS="\"GITISH_POSITIONALS\":\"[\\\"$CLI\\\",\\\"gitish\\\"]\""
run_subcommand_case "{\"GITISH_COMMAND\":\"\",\"GITISH_VERBOSE\":\"true\",$BASE_POSITIONALS}" gitish -v
run_subcommand_case "{\"GITISH_COMMAND\":\"\",\"GITISH_VERBOSE\":\"false\",\"GITISH_AUTHOR\":\"alice\",$BASE_POSITIONALS}" gitish -A alice
run_subcommand_case "{\"GITISH_COMMAND\":\"add\",\"GITISH_CMD_ADD\":\"true\",\"GITISH_VERBOSE\":\"false\",\"GITISH_ADD_ALL\":\"true\",$BASE_POSITIONALS}" gitish add -A
run_subcommand_case "{\"GITISH_COMMAND\":\"add\",\"GITISH_CMD_ADD\":\"true\",\"GITISH_VERBOSE\":\"true\",$BASE_POSITIONALS}" gitish add --verbose
run_subcommand_case "{\"GITISH_COMMAND\":\"commit\",\"GITISH_VERBOSE\":\"false\",\"GITISH_COMMIT_ALL\":\"true\",\"GITISH_COMMIT_MESSAGE\":\"fix stuff\",$BASE_POSITIONALS}" gitish ci -a -m 'fix stuff'
# the git-style mixed bundle spelling of the same invocation, resolved in the
# commit command scope, plus an inherited global bool joining the bundle
run_subcommand_case "{\"GITISH_COMMAND\":\"commit\",\"GITISH_VERBOSE\":\"false\",\"GITISH_COMMIT_ALL\":\"true\",\"GITISH_COMMIT_MESSAGE\":\"fix stuff\",$BASE_POSITIONALS}" gitish ci -am 'fix stuff'
run_subcommand_case "{\"GITISH_COMMAND\":\"commit\",\"GITISH_VERBOSE\":\"true\",\"GITISH_COMMIT_ALL\":\"true\",\"GITISH_COMMIT_MESSAGE\":\"wip\",$BASE_POSITIONALS}" gitish ci -vam wip
# The dry-run command resolver must consume a mixed bundle's separated value
# exactly like the real pass, or it would mistake "Alex" for a positional and
# fail to discover the following commit command.
run_subcommand_case "{\"GITISH_COMMAND\":\"commit\",\"GITISH_VERBOSE\":\"true\",\"GITISH_AUTHOR\":\"Alex\",\"GITISH_COMMIT_ALL\":\"true\",\"GITISH_COMMIT_MESSAGE\":\"scoped\",$BASE_POSITIONALS}" gitish -vA Alex ci -am scoped
run_subcommand_case "{\"GITISH_COMMAND\":\"remote add\",\"GITISH_CMD_REMOTE_ADD\":\"true\",\"GITISH_VERBOSE\":\"false\",\"GITISH_REMOTE_ADD_FETCH\":\"true\",\"GITISH_REMOTE_ADD_TRACK\":\"dev\",$BASE_POSITIONALS}" gitish remote add -f --track=dev
run_subcommand_case "{\"GITISH_COMMAND\":\"remote\",\"GITISH_VERBOSE\":\"false\",\"GITISH_REMOTE_VERBOSE\":\"true\",$BASE_POSITIONALS}" gitish remote -v
run_subcommand_case "{\"GITISH_COMMAND\":\"add\",\"GITISH_CMD_ADD\":\"true\",\"GITISH_VERBOSE\":\"false\",\"GITISH_POSITIONALS\":\"[\\\"$CLI\\\",\\\"gitish\\\",\\\"foo\\\",\\\"commit\\\"]\"}" gitish add foo commit
run_subcommand_case "{\"GITISH_COMMAND\":\"remote add\",\"GITISH_CMD_REMOTE_ADD\":\"true\",\"GITISH_VERBOSE\":\"false\",\"GITISH_REMOTE_ADD_FETCH\":\"false\",\"GITISH_POSITIONALS\":\"[\\\"$CLI\\\",\\\"gitish\\\",\\\"-f\\\"]\"}" gitish remote add -- -f

# lenient fallback: a wrapper may strip the subcommand before argv reaches the
# parser; scoped flags then resolve globally when unambiguous
run_subcommand_case "{\"GITISH_COMMAND\":\"\",\"GITISH_VERBOSE\":\"false\",\"GITISH_ADD_CHMOD\":\"+x\",$BASE_POSITIONALS}" gitish --chmod +x
run_subcommand_case "{\"GITISH_COMMAND\":\"\",\"GITISH_VERBOSE\":\"false\",\"GITISH_COMMIT_ALL\":\"true\",$BASE_POSITIONALS}" gitish -a
# ambiguous names (add --all vs commit --all) are accepted but not applied,
# and not reported unknown
run_subcommand_case "{\"GITISH_COMMAND\":\"\",\"GITISH_VERBOSE\":\"false\",$BASE_POSITIONALS}" gitish --all
# true typos are still collected
run_subcommand_case "{\"GITISH_COMMAND\":\"\",\"GITISH_VERBOSE\":\"false\",$BASE_POSITIONALS,\"GITISH_UNKNOWN_OPTIONS\":\"[\\\"--wat\\\"]\"}" gitish --wat
# lenient fallback never applies once a command matched
run_subcommand_case "{\"GITISH_COMMAND\":\"commit\",\"GITISH_VERBOSE\":\"false\",$BASE_POSITIONALS,\"GITISH_UNKNOWN_OPTIONS\":\"[\\\"--chmod=755\\\"]\"}" gitish commit --chmod=755
# [global.flags.*] is the explicit global namespace and reaches every scope
run_subcommand_case "{\"GITISH_COMMAND\":\"remote add\",\"GITISH_CMD_REMOTE_ADD\":\"true\",\"GITISH_VERBOSE\":\"false\",\"GITISH_REMOTE_ADD_FETCH\":\"false\",\"GITISH_COLOR\":\"true\",$BASE_POSITIONALS}" gitish remote add --color

actual="$(cd "$SUBCOMMANDS_DIR" && "$CLI" audit)"
expected='{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected clean subcommand audit: %s\nActual:                          %s\n' "$expected" "$actual" >&2
  exit 1
fi

generated_subcommands_ts="$("$CLI" generate typescript "$SUBCOMMANDS_DIR/.cli-flags.toml" --name GitishConfig)"
case "$generated_subcommands_ts" in
  *'GITISH_ADD_ALL?: boolean;'*'GITISH_CMD_ADD?: boolean;'*'GITISH_COMMAND?: string;'*)
    ;;
  *)
    printf 'Generated TypeScript should include subcommand and command envs:\n%s\n' "$generated_subcommands_ts" >&2
    exit 1
    ;;
esac
case "$generated_subcommands_ts" in
  *'GITISH_REMOTE_ADD_FETCH?: boolean;'*)
    ;;
  *)
    printf 'Command-scoped defaults should generate optional fields:\n%s\n' "$generated_subcommands_ts" >&2
    exit 1
    ;;
esac

generated_subcommands_schema="$("$CLI" generate json-schema "$SUBCOMMANDS_DIR/.cli-flags.toml" --name GitishConfig)"
case "$generated_subcommands_schema" in
  *'"GITISH_CMD_REMOTE_ADD"'*'"GITISH_COMMAND"'*)
    ;;
  *)
    printf 'Generated JSON Schema should include command envs:\n%s\n' "$generated_subcommands_schema" >&2
    exit 1
    ;;
esac

subcommand_help="$(cd "$SUBCOMMANDS_DIR" && COLUMNS=100 "$CLI" gitish --help)"
case "$subcommand_help" in
  *'Command: gitish [COMMAND] [OPTIONS]'*'Commands:'*'| add '*'Add file contents to the index.'*'| commit, ci '*'| remote add '*"Run 'gitish <command> --help' for command-specific options."*)
    ;;
  *)
    printf 'Unexpected top-level subcommand help:\n%s\n' "$subcommand_help" >&2
    exit 1
    ;;
esac
case "$subcommand_help" in
  *'--chmod'*|*'--fetch'*)
    printf 'Top-level help should not list subcommand-scoped flags:\n%s\n' "$subcommand_help" >&2
    exit 1
    ;;
esac

scoped_help="$(cd "$SUBCOMMANDS_DIR" && COLUMNS=100 "$CLI" gitish remote add --help)"
case "$scoped_help" in
  *'Command: gitish remote add [OPTIONS]'*'Add a remote.'*'--fetch'*'--track'*'--author'*)
    ;;
  *)
    printf 'Unexpected scoped subcommand help:\n%s\n' "$scoped_help" >&2
    exit 1
    ;;
esac
case "$scoped_help" in
  *'--chmod'*|*'--message'*)
    printf 'Scoped help should not list sibling-command flags:\n%s\n' "$scoped_help" >&2
    exit 1
    ;;
esac

shadowed_help="$(cd "$SUBCOMMANDS_DIR" && COLUMNS=100 "$CLI" gitish add --help)"
case "$shadowed_help" in
  *'-A, --all'*'--author'*)
    ;;
  *)
    printf 'Scoped help should include shadowing and inherited flags:\n%s\n' "$shadowed_help" >&2
    exit 1
    ;;
esac
case "$shadowed_help" in
  *'-A, --author'*)
    printf 'Scoped help should hide shadowed short flags:\n%s\n' "$shadowed_help" >&2
    exit 1
    ;;
esac

subcommand_completion_bash="$("$CLI" completion bash gitish "$SUBCOMMANDS_DIR/.cli-flags.toml")"
case "$subcommand_completion_bash" in
  *"'') printf '%s' 'add commit ci remote' ;;"*"'remote') printf '%s' 'add' ;;"*'complete -o default -F _flags2env_complete_gitish'*)
    ;;
  *)
    printf 'Bash completion should be scope-aware:\n%s\n' "$subcommand_completion_bash" >&2
    exit 1
    ;;
esac
case "$subcommand_completion_bash" in
  *"'remote add') printf '%s' '--fetch"*)
    ;;
  *)
    printf 'Bash completion should carry nested scope options:\n%s\n' "$subcommand_completion_bash" >&2
    exit 1
    ;;
esac

subcommand_completion_zsh="$("$CLI" completion zsh gitish "$SUBCOMMANDS_DIR/.cli-flags.toml")"
case "$subcommand_completion_zsh" in
  *'#compdef gitish'*"'') printf '%s' 'add commit ci remote' ;;"*'compadd -- ${=cmds}'*)
    ;;
  *)
    printf 'Zsh completion should be scope-aware:\n%s\n' "$subcommand_completion_zsh" >&2
    exit 1
    ;;
esac

bash "$ROOT_DIR/tests/completion/run.bash"

SUBCOMMANDS_DEEP_DIR="$ROOT_DIR/tests/subcommands-deep"
run_deep_case() {
  expected="$1"
  shift
  actual="$(cd "$SUBCOMMANDS_DEEP_DIR" && "$CLI" "$@")"
  if [ "$actual" != "$expected" ]; then
    printf 'Expected deep subcommand parse: %s\nActual:                         %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

DEEP_BASE_POSITIONALS="\"TOOL_POSITIONALS\":\"[\\\"$CLI\\\",\\\"tool\\\"]\""
# four-level command path with a flag scoped four levels deep
run_deep_case "{\"TOOL_COMMAND\":\"ws remote add tag\",\"TOOL_CMD_TAG\":\"true\",\"TOOL_DRY_RUN\":\"false\",\"TOOL_TAG_NAME\":\"v1\",\"TOOL_TAG_DRY_RUN\":\"true\",$DEEP_BASE_POSITIONALS}" tool ws remote add tag --name v1 -n
# aliases at every level resolve to the same canonical command path and marker
run_deep_case "{\"TOOL_COMMAND\":\"ws remote add tag\",\"TOOL_CMD_TAG\":\"true\",\"TOOL_DRY_RUN\":\"false\",\"TOOL_TAG_NAME\":\"v2\",\"TOOL_TAG_DRY_RUN\":\"true\",$DEEP_BASE_POSITIONALS}" tool workspace remotes create annotate --name v2 -n
# -n resolves to the ws-scoped flag one level down
run_deep_case "{\"TOOL_COMMAND\":\"ws\",\"TOOL_DRY_RUN\":\"false\",\"TOOL_WS_DRY_RUN\":\"true\",$DEEP_BASE_POSITIONALS}" tool ws -n
# a separated flag value that looks like a command must not select the command
run_deep_case "{\"TOOL_COMMAND\":\"\",\"TOOL_DRY_RUN\":\"false\",\"TOOL_LABEL\":\"ws\",\"TOOL_POSITIONALS\":\"[\\\"$CLI\\\",\\\"tool\\\",\\\"remote\\\"]\"}" tool --label ws remote
# a bool flag does not consume a following command token
run_deep_case "{\"TOOL_COMMAND\":\"ws\",\"TOOL_DRY_RUN\":\"true\",$DEEP_BASE_POSITIONALS}" tool --dry-run ws
# after the path locks, the first unmatched positional triggers stop_at_first_positional
run_deep_case "{\"TOOL_COMMAND\":\"ws\",\"TOOL_DRY_RUN\":\"false\",\"TOOL_POSITIONALS\":\"[\\\"$CLI\\\",\\\"tool\\\",\\\"foo\\\",\\\"remote\\\",\\\"--dry-run\\\"]\"}" tool ws foo remote --dry-run
# a bare -- always ends command matching
run_deep_case "{\"TOOL_COMMAND\":\"\",\"TOOL_DRY_RUN\":\"false\",\"TOOL_POSITIONALS\":\"[\\\"$CLI\\\",\\\"tool\\\",\\\"ws\\\"]\"}" tool -- ws
# unknown options are collected without ending command matching
run_deep_case "{\"TOOL_COMMAND\":\"ws remote\",\"TOOL_DRY_RUN\":\"false\",$DEEP_BASE_POSITIONALS,\"TOOL_UNKNOWN_OPTIONS\":\"[\\\"--wat\\\"]\"}" tool --wat ws remote
# [commands.ws.commands.remote] sets allow_unknown = true: unknown flags are
# collected before that scope is entered and tolerated after (including in
# nested subcommands, which inherit the setting)
run_deep_case "{\"TOOL_COMMAND\":\"ws remote\",\"TOOL_DRY_RUN\":\"false\",$DEEP_BASE_POSITIONALS,\"TOOL_UNKNOWN_OPTIONS\":\"[\\\"--wat\\\"]\"}" tool ws --wat remote --wat2
run_deep_case "{\"TOOL_COMMAND\":\"ws remote add\",\"TOOL_DRY_RUN\":\"false\",$DEEP_BASE_POSITIONALS}" tool ws remote add --wat3
# a runtime --no-allow-unknown override beats the per-command setting
run_deep_case "{\"TOOL_COMMAND\":\"ws remote\",\"TOOL_DRY_RUN\":\"false\",$DEEP_BASE_POSITIONALS,\"TOOL_UNKNOWN_OPTIONS\":\"[\\\"--wat4\\\"]\"}" tool --no-allow-unknown ws remote --wat4
# lenient fallback with stop_at_first_positional: a deeply scoped unique flag
# still applies when the wrapper stripped the command tokens
run_deep_case "{\"TOOL_COMMAND\":\"\",\"TOOL_DRY_RUN\":\"false\",\"TOOL_WS_REMOTE_ADD_URL\":\"http://x\",$DEEP_BASE_POSITIONALS}" tool --url http://x

actual="$(cd "$SUBCOMMANDS_DEEP_DIR" && "$CLI" audit)"
expected='{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected clean deep subcommand audit: %s\nActual:                               %s\n' "$expected" "$actual" >&2
  exit 1
fi

deep_help="$(cd "$SUBCOMMANDS_DEEP_DIR" && COLUMNS=110 "$CLI" tool --help)"
case "$deep_help" in
  *'Command: tool [COMMAND] [OPTIONS]'*'| ws, workspace '*'| ws remote, remotes '*'| ws remote add, create '*'| ws remote add tag, annotate '*)
    ;;
  *)
    printf 'Deep help should list the full nested command tree:\n%s\n' "$deep_help" >&2
    exit 1
    ;;
esac

deep_scoped_help="$(cd "$SUBCOMMANDS_DEEP_DIR" && COLUMNS=110 "$CLI" tool ws remote add tag --help)"
case "$deep_scoped_help" in
  *'Command: tool ws remote add tag [OPTIONS]'*'Tag a newly added workspace remote.'*'--name'*)
    ;;
  *)
    printf 'Deep scoped help should render the four-level command:\n%s\n' "$deep_scoped_help" >&2
    exit 1
    ;;
esac

# commands literally named "commands" and "flags" never clash with the table
# keywords because keyword and name positions strictly alternate
SUBCOMMANDS_NAMES_DIR="$ROOT_DIR/tests/subcommands-names"
actual="$(cd "$SUBCOMMANDS_NAMES_DIR" && "$CLI" tool commands --long)"
expected='{"NAMES_COMMAND":"commands","NAMES_COMMANDS_LONG":"true"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected command named "commands" parse: %s\nActual:                                  %s\n' "$expected" "$actual" >&2
  exit 1
fi
actual="$(cd "$SUBCOMMANDS_NAMES_DIR" && "$CLI" tool flags dump --path deep)"
expected='{"NAMES_COMMAND":"flags dump","NAMES_FLAGS_DUMP_PATH":"deep"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected command named "flags" parse: %s\nActual:                               %s\n' "$expected" "$actual" >&2
  exit 1
fi
actual="$(cd "$SUBCOMMANDS_NAMES_DIR" && "$CLI" audit)"
expected='{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected clean keyword-named-command audit: %s\nActual:                                     %s\n' "$expected" "$actual" >&2
  exit 1
fi

# shorthand nesting without the commands keyword is an audit error, not a
# silent no-op
INVALID_NESTING_CONFIG="$ROOT_DIR/tests/audit-invalid-subcommand-nesting/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_NESTING_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":1,"warningCount":0,"errors":["[commands.publish.init.flags.access] is not a valid commands table; nest subcommands with an explicit keyword, e.g. [commands.<name>.commands.<name>.flags.<flag>]"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected shorthand-nesting audit failure:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

INVALID_SUBCOMMAND_CONFIG="$ROOT_DIR/tests/audit-invalid-subcommand/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_SUBCOMMAND_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":4,"warningCount":0,"errors":["commands.add env \"GIT_CMD_ADD\" collides with flags.marker env","commands.add and commands.stage share a name or alias","commands.commit alias \"commit\" duplicates its canonical name","flags.all and flags.everything both use short flag \"A\""],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected failing subcommand audit status and report:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

MULTILINE_ARRAY_DIR="$ROOT_DIR/tests/multiline-arrays"
MULTILINE_ARRAY_CONFIG="$MULTILINE_ARRAY_DIR/.cli-flags.toml"
actual="$("$CLI" audit "$MULTILINE_ARRAY_CONFIG")"
expected='{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected clean multiline-array audit: %s\nActual:                                %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$(cd "$MULTILINE_ARRAY_DIR" && "$CLI" multiline --operation-mode fast --color=without-color)"
expected='{"MULTILINE_COMMAND":"","MODE":"fast","COLOR":"false"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected multiline global aliases: %s\nActual:                            %s\n' "$expected" "$actual" >&2
  exit 1
fi

actual="$(cd "$MULTILINE_ARRAY_DIR" && "$CLI" multiline ship --destination production --color=yes-color)"
expected='{"MULTILINE_COMMAND":"deploy","MODE":"safe","COLOR":"true","TARGET":"production"}'
if [ "$actual" != "$expected" ]; then
  printf 'Expected multiline command aliases: %s\nActual:                             %s\n' "$expected" "$actual" >&2
  exit 1
fi

multiline_help="$(cd "$MULTILINE_ARRAY_DIR" && COLUMNS=132 "$CLI" multiline --help)"
case "$multiline_help" in
  *'| Option(s)'*'| Env'*'| Description'*'More help: https://example.com/multiline'*)
    ;;
  *)
    printf 'Unexpected multiline-array help table:\n%s\n' "$multiline_help" >&2
    exit 1
    ;;
esac
case "$multiline_help" in
  *'| Type'*|*'| Default'*)
    printf 'Multiline help.columns should omit type/default:\n%s\n' "$multiline_help" >&2
    exit 1
    ;;
esac

INVALID_MULTILINE_TYPE_CONFIG="$ROOT_DIR/tests/audit-invalid-multiline-type/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_MULTILINE_TYPE_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":1,"warningCount":0,"errors":["env.ignore must be a list of env var names"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected invalid multiline element audit failure:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

INVALID_MULTILINE_UNCLOSED_CONFIG="$ROOT_DIR/tests/audit-invalid-multiline-unclosed/.cli-flags.toml"
set +e
actual="$("$CLI" audit "$INVALID_MULTILINE_UNCLOSED_CONFIG")"
status=$?
set -e
expected='{"ok":false,"errorCount":1,"warningCount":0,"errors":["help.columns must be a list of supported table column names"],"warnings":[]}'
if [ "$status" -eq 0 ] || [ "$actual" != "$expected" ]; then
  printf 'Expected unclosed multiline array audit failure:\n%s\nActual status: %s\nActual: %s\n' "$expected" "$status" "$actual" >&2
  exit 1
fi

# --- ./.env loading -----------------------------------------------------
#
# Resolution is argv > live env > ./.env > default, and only ./.env in the
# process working directory is read. The fixture uses F2E_DOTENV_* keys so an
# ambient variable cannot decide the outcome, and every case still clears them
# explicitly.

DOTENV_DIR="$ROOT_DIR/tests/dotenv"
DOTENV_OVERRIDE_DIR="$ROOT_DIR/tests/dotenv-global-override"
DOTENV_CLEAN="env -u F2E_DOTENV_PORT -u F2E_DOTENV_HOST -u F2E_DOTENV_TOKEN -u F2E_DOTENV_DEBUG -u FLAGS2ENV_DOTENV"

expect_dotenv() {
  label="$1"
  expected="$2"
  actual="$3"
  if [ "$actual" != "$expected" ]; then
    printf '%s\nExpected: %s\nActual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

# .env supplies every declared key it names; the undeclared key stays out
expect_dotenv 'Expected .env values' \
  '{"F2E_DOTENV_PORT":"8080","F2E_DOTENV_DEBUG":"true","F2E_DOTENV_HOST":"db.internal","F2E_DOTENV_TOKEN":"from-dotenv"}' \
  "$(cd "$DOTENV_DIR" && $DOTENV_CLEAN "$CLI" app)"

# argv beats .env
expect_dotenv 'Expected argv to beat .env' \
  '{"F2E_DOTENV_PORT":"9999","F2E_DOTENV_DEBUG":"true","F2E_DOTENV_HOST":"db.internal","F2E_DOTENV_TOKEN":"from-dotenv"}' \
  "$(cd "$DOTENV_DIR" && $DOTENV_CLEAN "$CLI" app --port 9999)"

# the live environment beats .env for a key that did not opt into override,
# while the opted-in token still takes its .env value
expect_dotenv 'Expected live env to beat .env except for the override key' \
  '{"F2E_DOTENV_PORT":"7777","F2E_DOTENV_DEBUG":"true","F2E_DOTENV_HOST":"db.internal","F2E_DOTENV_TOKEN":"from-dotenv"}' \
  "$(cd "$DOTENV_DIR" && $DOTENV_CLEAN F2E_DOTENV_PORT=7777 F2E_DOTENV_TOKEN=from-live "$CLI" app)"

# argv still outranks the live environment
expect_dotenv 'Expected argv to beat the live environment' \
  '{"F2E_DOTENV_PORT":"9999","F2E_DOTENV_DEBUG":"true","F2E_DOTENV_HOST":"db.internal","F2E_DOTENV_TOKEN":"from-dotenv"}' \
  "$(cd "$DOTENV_DIR" && $DOTENV_CLEAN F2E_DOTENV_PORT=7777 "$CLI" app --port 9999)"

# [env] override = true flips .env above the live environment for every key
expect_dotenv 'Expected [env] override to lift .env over the live environment' \
  '{"F2E_DOTENV_PORT":"8080","F2E_DOTENV_DEBUG":"true","F2E_DOTENV_HOST":"db.internal","F2E_DOTENV_TOKEN":"from-dotenv"}' \
  "$(cd "$DOTENV_OVERRIDE_DIR" && $DOTENV_CLEAN F2E_DOTENV_PORT=7777 "$CLI" app)"

expect_dotenv 'Expected argv to beat an overriding .env' \
  '{"F2E_DOTENV_PORT":"9999","F2E_DOTENV_DEBUG":"true","F2E_DOTENV_HOST":"db.internal","F2E_DOTENV_TOKEN":"from-dotenv"}' \
  "$(cd "$DOTENV_OVERRIDE_DIR" && $DOTENV_CLEAN F2E_DOTENV_PORT=7777 "$CLI" app --port 9999)"

# FLAGS2ENV_DOTENV=0 skips the file without touching the config
expect_dotenv 'Expected FLAGS2ENV_DOTENV=0 to skip .env' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false"}' \
  "$(cd "$DOTENV_DIR" && $DOTENV_CLEAN FLAGS2ENV_DOTENV=0 "$CLI" app)"

# [env] load = false is how a daemon refuses to take values from an ambient
# working directory, so an ambient variable must not be able to undo it
DOTENV_NO_LOAD_DIR="$TMP_TEST_DIR/dotenv-no-load"
mkdir -p "$DOTENV_NO_LOAD_DIR"
{
  printf '[env]\nload = false\n'
  cat "$DOTENV_DIR/.cli-flags.toml"
} > "$DOTENV_NO_LOAD_DIR/.cli-flags.toml"
cp "$DOTENV_DIR/.env" "$DOTENV_NO_LOAD_DIR/.env"
expect_dotenv 'Expected FLAGS2ENV_DOTENV=1 not to defeat [env] load = false' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false"}' \
  "$(cd "$DOTENV_NO_LOAD_DIR" && $DOTENV_CLEAN FLAGS2ENV_DOTENV=1 "$CLI" app)"

# a ./.env symlink is followed like a regular file
DOTENV_LINK_DIR="$TMP_TEST_DIR/dotenv-symlink"
mkdir -p "$DOTENV_LINK_DIR/shared"
cp "$DOTENV_DIR/.cli-flags.toml" "$DOTENV_LINK_DIR/.cli-flags.toml"
cp "$DOTENV_DIR/.env" "$DOTENV_LINK_DIR/shared/team.env"
ln -s shared/team.env "$DOTENV_LINK_DIR/.env"
expect_dotenv 'Expected a symlinked ./.env to be followed' \
  '{"F2E_DOTENV_PORT":"8080","F2E_DOTENV_DEBUG":"true","F2E_DOTENV_HOST":"db.internal","F2E_DOTENV_TOKEN":"from-dotenv"}' \
  "$(cd "$DOTENV_LINK_DIR" && $DOTENV_CLEAN "$CLI" app)"

# only the working directory is searched. Config discovery still walks upward,
# so running from a subdirectory finds the parent's .cli-flags.toml and must
# not pick up the .env sitting beside it.
DOTENV_NESTED_ROOT="$TMP_TEST_DIR/dotenv-nested"
mkdir -p "$DOTENV_NESTED_ROOT/child"
cp "$DOTENV_DIR/.cli-flags.toml" "$DOTENV_NESTED_ROOT/.cli-flags.toml"
cp "$DOTENV_DIR/.env" "$DOTENV_NESTED_ROOT/.env"
expect_dotenv 'Expected .env lookup not to walk upward with config discovery' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false"}' \
  "$(cd "$DOTENV_NESTED_ROOT/child" && $DOTENV_CLEAN "$CLI" app)"

# a .env value that does not fit its declared type is a reported parse error
# rather than a silent substitution
DOTENV_BAD_DIR="$TMP_TEST_DIR/dotenv-bad"
mkdir -p "$DOTENV_BAD_DIR"
{
  cat "$DOTENV_DIR/.cli-flags.toml"
  printf '\n[parse]\nerrors_env = "F2E_DOTENV_ERRORS"\n'
} > "$DOTENV_BAD_DIR/.cli-flags.toml"
printf 'F2E_DOTENV_PORT=not-a-number\n' > "$DOTENV_BAD_DIR/.env"
expect_dotenv 'Expected an invalid .env value to be reported and skipped' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false","F2E_DOTENV_ERRORS":"[\".env F2E_DOTENV_PORT value \\\"not-a-number\\\" is not a valid integer for flags.port\"]"}' \
  "$(cd "$DOTENV_BAD_DIR" && $DOTENV_CLEAN "$CLI" app)"

# the ambient environment is not this parser's to police: a live value that
# does not fit its declared type is skipped without becoming a parse error
DOTENV_NO_FILE_DIR="$TMP_TEST_DIR/dotenv-no-file"
mkdir -p "$DOTENV_NO_FILE_DIR"
cp "$DOTENV_BAD_DIR/.cli-flags.toml" "$DOTENV_NO_FILE_DIR/.cli-flags.toml"
expect_dotenv 'Expected an invalid live env value to be skipped silently' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false"}' \
  "$(cd "$DOTENV_NO_FILE_DIR" && $DOTENV_CLEAN F2E_DOTENV_PORT=not-a-number "$CLI" app)"

# --- .env file format ---------------------------------------------------
#
# Each case writes one ./.env into a scratch directory and reads back the
# resolved map. Only F2E_DOTENV_HOST (string) and F2E_DOTENV_PORT (integer)
# vary, so the expectation stays readable.

DOTENV_FMT_DIR="$TMP_TEST_DIR/dotenv-format"
mkdir -p "$DOTENV_FMT_DIR"
cp "$DOTENV_DIR/.cli-flags.toml" "$DOTENV_FMT_DIR/.cli-flags.toml"

# expect_dotenv_format <label> <printf format for .env> <expected host value>
expect_dotenv_format() {
  printf "$2" > "$DOTENV_FMT_DIR/.env"
  expect_dotenv "$1" \
    "{\"F2E_DOTENV_PORT\":\"3000\",\"F2E_DOTENV_DEBUG\":\"false\",\"F2E_DOTENV_HOST\":\"$3\"}" \
    "$(cd "$DOTENV_FMT_DIR" && $DOTENV_CLEAN "$CLI" app)"
}

expect_dotenv_format 'Expected a value with no trailing newline' \
  'F2E_DOTENV_HOST=tail' 'tail'
expect_dotenv_format 'Expected CRLF line endings to be handled' \
  'F2E_DOTENV_HOST=crlf\r\n' 'crlf'
expect_dotenv_format 'Expected whitespace around the key and = to be trimmed' \
  '   F2E_DOTENV_HOST   =   spaced   \n' 'spaced'
expect_dotenv_format 'Expected an = inside the value to be kept' \
  'F2E_DOTENV_HOST=a=b=c\n' 'a=b=c'
expect_dotenv_format 'Expected an export prefix to be accepted' \
  'export F2E_DOTENV_HOST=exported\n' 'exported'
expect_dotenv_format 'Expected the last assignment of a repeated key to win' \
  'F2E_DOTENV_HOST=first\nF2E_DOTENV_HOST=second\n' 'second'
expect_dotenv_format 'Expected a malformed line to be skipped, not to end the file' \
  'no-equals-here\nF2E_DOTENV_HOST=survives\n' 'survives'
expect_dotenv_format 'Expected an invalid key to be skipped' \
  '9BAD=x\nF2E_DOTENV_HOST=survives\n' 'survives'
expect_dotenv_format 'Expected double quotes to be stripped' \
  'F2E_DOTENV_HOST="double quoted"\n' 'double quoted'
expect_dotenv_format 'Expected single quotes to be literal' \
  'F2E_DOTENV_HOST=\047raw\\tvalue\047\n' 'raw\\tvalue'
expect_dotenv_format 'Expected an unterminated quote to keep what it read' \
  'F2E_DOTENV_HOST="unterminated\n' 'unterminated'
expect_dotenv_format 'Expected a comment after a closing quote to be dropped' \
  'F2E_DOTENV_HOST="quoted"   # trailing\n' 'quoted'
expect_dotenv_format 'Expected a comment after an unquoted value to be dropped' \
  'F2E_DOTENV_HOST=bare # trailing\n' 'bare'
expect_dotenv_format 'Expected a leading # to stay part of the value' \
  'F2E_DOTENV_HOST=#fff\n' '#fff'
expect_dotenv_format 'Expected a # with no leading space to stay in the value' \
  'F2E_DOTENV_HOST=a#b\n' 'a#b'
expect_dotenv_format 'Expected no variable expansion' \
  'F2E_DOTENV_HOST=$HOME\n' '$HOME'
expect_dotenv_format 'Expected a UTF-8 BOM before the first key to be skipped' \
  '\357\273\277F2E_DOTENV_HOST=bom\n' 'bom'

printf 'F2E_DOTENV_HOST=\n' > "$DOTENV_FMT_DIR/.env"
expect_dotenv 'Expected an empty .env value to set an empty string' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false","F2E_DOTENV_HOST":""}' \
  "$(cd "$DOTENV_FMT_DIR" && $DOTENV_CLEAN "$CLI" app)"

printf '\n\n#only comments\n\n   \n' > "$DOTENV_FMT_DIR/.env"
expect_dotenv 'Expected a comment-only .env to change nothing' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false"}' \
  "$(cd "$DOTENV_FMT_DIR" && $DOTENV_CLEAN "$CLI" app)"

: > "$DOTENV_FMT_DIR/.env"
expect_dotenv 'Expected an empty .env to change nothing' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false"}' \
  "$(cd "$DOTENV_FMT_DIR" && $DOTENV_CLEAN "$CLI" app)"

# --- .env file kinds ----------------------------------------------------
#
# ./.env comes from an ambient working directory, so anything that is not a
# regular file must be declined rather than trusted or waited on.

DOTENV_KIND_DIR="$TMP_TEST_DIR/dotenv-kinds"
mkdir -p "$DOTENV_KIND_DIR"
cp "$DOTENV_DIR/.cli-flags.toml" "$DOTENV_KIND_DIR/.cli-flags.toml"
DOTENV_KIND_DEFAULTS='{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false"}'

mkdir "$DOTENV_KIND_DIR/.env"
expect_dotenv 'Expected a .env directory to be declined' \
  "$DOTENV_KIND_DEFAULTS" \
  "$(cd "$DOTENV_KIND_DIR" && $DOTENV_CLEAN "$CLI" app)"
rmdir "$DOTENV_KIND_DIR/.env"

ln -s "$DOTENV_KIND_DIR/nothing-here" "$DOTENV_KIND_DIR/.env"
expect_dotenv 'Expected a broken .env symlink to be declined' \
  "$DOTENV_KIND_DEFAULTS" \
  "$(cd "$DOTENV_KIND_DIR" && $DOTENV_CLEAN "$CLI" app)"
rm -f "$DOTENV_KIND_DIR/.env"

# a symlink chain still resolves, because only the final target's kind matters
mkdir -p "$DOTENV_KIND_DIR/shared"
printf 'F2E_DOTENV_HOST=via-two-hops\n' > "$DOTENV_KIND_DIR/shared/real.env"
ln -s shared/real.env "$DOTENV_KIND_DIR/hop.env"
ln -s hop.env "$DOTENV_KIND_DIR/.env"
expect_dotenv 'Expected a .env symlink chain to resolve' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false","F2E_DOTENV_HOST":"via-two-hops"}' \
  "$(cd "$DOTENV_KIND_DIR" && $DOTENV_CLEAN "$CLI" app)"
rm -f "$DOTENV_KIND_DIR/.env" "$DOTENV_KIND_DIR/hop.env"

# a fifo would park a blocking open() until some writer appeared; the command
# must decline it and finish instead of hanging
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$DOTENV_KIND_DIR/.env" 2>/dev/null; then
  expect_dotenv 'Expected a .env fifo to be declined rather than waited on' \
    "$DOTENV_KIND_DEFAULTS" \
    "$(cd "$DOTENV_KIND_DIR" && $DOTENV_CLEAN "$CLI" app)"
  rm -f "$DOTENV_KIND_DIR/.env"
fi

# an unreadable .env is not fatal
printf 'F2E_DOTENV_HOST=unreadable\n' > "$DOTENV_KIND_DIR/.env"
chmod 000 "$DOTENV_KIND_DIR/.env"
if [ "$(id -u)" != "0" ]; then
  expect_dotenv 'Expected an unreadable .env not to be fatal' \
    "$DOTENV_KIND_DEFAULTS" \
    "$(cd "$DOTENV_KIND_DIR" && $DOTENV_CLEAN "$CLI" app)"
fi
chmod 644 "$DOTENV_KIND_DIR/.env"
rm -f "$DOTENV_KIND_DIR/.env"

# oversized input is bounded rather than truncating the rest of the file away
DOTENV_BIG_DIR="$TMP_TEST_DIR/dotenv-big"
mkdir -p "$DOTENV_BIG_DIR"
{
  cat "$DOTENV_DIR/.cli-flags.toml"
  printf '\n[parse]\nerrors_env = "F2E_DOTENV_ERRORS"\n'
} > "$DOTENV_BIG_DIR/.cli-flags.toml"
{
  i=0
  while [ "$i" -lt 600 ]; do
    printf 'F2E_DOTENV_PAD%s=v\n' "$i"
    i=$((i + 1))
  done
  printf 'F2E_DOTENV_HOST=after-600-undeclared-keys\n'
} > "$DOTENV_BIG_DIR/.env"
expect_dotenv 'Expected declared keys to survive many undeclared ones' \
  '{"F2E_DOTENV_PORT":"3000","F2E_DOTENV_DEBUG":"false","F2E_DOTENV_HOST":"after-600-undeclared-keys"}' \
  "$(cd "$DOTENV_BIG_DIR" && $DOTENV_CLEAN "$CLI" app)"

# One logical line longer than the read buffer arrives in several chunks. The
# chunks after the first are the tail of that value, so a value ending in
# something that looks like an assignment must not set that key, and the next
# real line must still be read.
{
  printf 'F2E_DOTENV_HOST='
  i=0
  while [ "$i" -lt 600 ]; do
    printf '0123456789012345'
    i=$((i + 1))
  done
  printf 'F2E_DOTENV_PORT=9999\n'
  printf 'F2E_DOTENV_TOKEN=next-real-line\n'
} > "$DOTENV_BIG_DIR/.env"
dotenv_big="$(cd "$DOTENV_BIG_DIR" && $DOTENV_CLEAN "$CLI" app)"
case "$dotenv_big" in
  *'"F2E_DOTENV_PORT":"9999"'*)
    printf 'The tail of an over-long .env line must not set another key:\n%s\n' "$dotenv_big" >&2
    exit 1
    ;;
esac
case "$dotenv_big" in
  *'"F2E_DOTENV_TOKEN":"next-real-line"'*)
    ;;
  *)
    printf 'The line after an over-long .env line must still be read:\n%s\n' "$dotenv_big" >&2
    exit 1
    ;;
esac
case "$dotenv_big" in
  *'"F2E_DOTENV_ERRORS":"[\".env:1: line exceeds the 4095-byte read buffer; value was bounded and its tail skipped\"]"'*)
    ;;
  *)
    printf 'An over-long .env line must be reported through errors_env:\n%s\n' "$dotenv_big" >&2
    exit 1
    ;;
esac
dotenv_big_len="$(printf '%s' "$dotenv_big" | sed -e 's/.*"F2E_DOTENV_HOST":"//' -e 's/".*//' | awk '{print length($0)}')"
if [ "$dotenv_big_len" -ne 1023 ]; then
  printf 'Expected an oversized .env value to be bounded at 1023 bytes; got %s\n' "$dotenv_big_len" >&2
  exit 1
fi

# --- [order-of-preference] ----------------------------------------------
#
# Each key in the fixture declares a different ranking. Every case supplies all
# three sources at once, so the winner names the rank that actually applied.

DOTENV_ORDER_DIR="$ROOT_DIR/tests/dotenv-order"
DOTENV_ORDER_CLEAN="env -u F2E_ORDER_FILE_FIRST -u F2E_ORDER_SHELL_FIRST \
  -u F2E_ORDER_FILE_OVER_FLAGS -u F2E_ORDER_BRACKETS -u F2E_ORDER_QUOTED \
  -u F2E_ORDER_DEFAULT -u FLAGS2ENV_DOTENV"
DOTENV_ORDER_SHELL="F2E_ORDER_FILE_FIRST=shell F2E_ORDER_SHELL_FIRST=shell \
  F2E_ORDER_FILE_OVER_FLAGS=shell F2E_ORDER_BRACKETS=shell F2E_ORDER_QUOTED=shell \
  F2E_ORDER_DEFAULT=shell"
DOTENV_ORDER_FLAGS="--file-first flag --shell-first flag --file-over-flags flag \
  --brackets flag --quoted flag --default-order flag"

order_audit="$("$CLI" audit "$DOTENV_ORDER_DIR/.cli-flags.toml")"
expect_dotenv 'Expected a clean order-of-preference audit' \
  '{"ok":true,"errorCount":0,"warningCount":0,"errors":[],"warnings":[]}' \
  "$order_audit"

# shellcheck disable=SC2086
expect_dotenv 'Expected each key to resolve by its own declared order' \
  '{"F2E_ORDER_FILE_FIRST":"file","F2E_ORDER_SHELL_FIRST":"shell","F2E_ORDER_FILE_OVER_FLAGS":"file","F2E_ORDER_BRACKETS":"file","F2E_ORDER_QUOTED":"file","F2E_ORDER_DEFAULT":"flag"}' \
  "$(cd "$DOTENV_ORDER_DIR" && $DOTENV_ORDER_CLEAN $DOTENV_ORDER_SHELL "$CLI" app $DOTENV_ORDER_FLAGS)"

# with the file out of the way each key falls to the next rank in its own list;
# the completed lists put the omitted source last, so
# (env_shell, flags) -> flags and (env_file, flags) -> flags
DOTENV_ORDER_NOFILE="$TMP_TEST_DIR/dotenv-order-nofile"
mkdir -p "$DOTENV_ORDER_NOFILE"
cp "$DOTENV_ORDER_DIR/.cli-flags.toml" "$DOTENV_ORDER_NOFILE/.cli-flags.toml"
# shellcheck disable=SC2086
expect_dotenv 'Expected each key to fall to the next rank when .env is absent' \
  '{"F2E_ORDER_FILE_FIRST":"shell","F2E_ORDER_SHELL_FIRST":"shell","F2E_ORDER_FILE_OVER_FLAGS":"flag","F2E_ORDER_BRACKETS":"shell","F2E_ORDER_QUOTED":"flag","F2E_ORDER_DEFAULT":"flag"}' \
  "$(cd "$DOTENV_ORDER_NOFILE" && $DOTENV_ORDER_CLEAN $DOTENV_ORDER_SHELL "$CLI" app $DOTENV_ORDER_FLAGS)"

# [env] order sets the config-wide default for keys the table omits
DOTENV_ORDER_GLOBAL="$TMP_TEST_DIR/dotenv-order-global"
mkdir -p "$DOTENV_ORDER_GLOBAL"
{
  printf '[env]\norder = (env_file, env_shell, flags)\n\n'
  printf '[flags.host]\nenv = "F2E_ORDER_DEFAULT"\naliases = ["default-order"]\ntype = "string"\n'
} > "$DOTENV_ORDER_GLOBAL/.cli-flags.toml"
printf 'F2E_ORDER_DEFAULT=file\n' > "$DOTENV_ORDER_GLOBAL/.env"
expect_dotenv 'Expected [env] order to set the config-wide default' \
  '{"F2E_ORDER_DEFAULT":"file"}' \
  "$(cd "$DOTENV_ORDER_GLOBAL" && $DOTENV_ORDER_CLEAN F2E_ORDER_DEFAULT=shell "$CLI" app --default-order flag)"

# malformed preference lists fail the audit rather than resolving to something
expect_order_audit_error() {
  order_dir="$TMP_TEST_DIR/dotenv-order-bad"
  rm -rf "$order_dir"
  mkdir -p "$order_dir"
  {
    printf '[order-of-preference]\n%s\n\n' "$2"
    printf '[flags.host]\nenv = "F2E_ORDER_DEFAULT"\naliases = ["default-order"]\ntype = "string"\n'
  } > "$order_dir/.cli-flags.toml"
  set +e
  order_actual="$("$CLI" audit "$order_dir/.cli-flags.toml")"
  order_status=$?
  set -e
  if [ "$order_status" -eq 0 ]; then
    printf '%s: expected a failing audit, got: %s\n' "$1" "$order_actual" >&2
    exit 1
  fi
  case "$order_actual" in
    *"$3"*)
      ;;
    *)
      printf '%s\nExpected message containing: %s\nActual: %s\n' "$1" "$3" "$order_actual" >&2
      exit 1
      ;;
  esac
}

expect_order_audit_error 'Expected an unknown source to fail the audit' \
  'F2E_ORDER_DEFAULT = (env_file, nonsense)' \
  'names an unknown source'
expect_order_audit_error 'Expected a repeated source to fail the audit' \
  'F2E_ORDER_DEFAULT = (env_file, env_file)' \
  'repeats a source'
expect_order_audit_error 'Expected a single-entry list to fail the audit' \
  'F2E_ORDER_DEFAULT = (env_file)' \
  'needs at least two sources'
expect_order_audit_error 'Expected a non-list value to fail the audit' \
  'F2E_ORDER_DEFAULT = env_file' \
  'must be a list'
expect_order_audit_error 'Expected an undeclared env key to fail the audit' \
  'F2E_ORDER_NOT_DECLARED = (env_file, flags)' \
  'is not declared as an env by any [flags.*] table'

# Regression: a long inline `--flag=value` must not be truncated.
#
# The long-option parser used to copy the whole "name=value" token into the
# F2E_MAX_NAME-sized name buffer and only then split on '=', which bounded the
# *value* by the name buffer. Values longer than that were silently cut down to
# a plausible-looking wrong string — a truncated path, URL, or JSON payload.
#
# tests/long-inline-value/ exists for this check; without it the fixture is
# inert and the fix has no guard.
LONG_VALUE_CONFIG="$ROOT_DIR/tests/long-inline-value/.cli-flags.toml"
long_value="/var/folders/qr/l0klf0r566z1qdsfgcg9j7s00000gn/T/deeply/nested/build/output/definition.json"
expected="export F2E_LONG_PATH='$long_value'"

inline="$("$CLI" shell-env --config "$LONG_VALUE_CONFIG" -- prog "--path=$long_value")"
if [ "$inline" != "$expected" ]; then
  printf 'Long inline value was altered:\nExpected: %s\nActual:   %s\n' "$expected" "$inline" >&2
  exit 1
fi

# The separated form never had the bug; asserting both keeps the two spellings
# agreeing about what the value is.
separated="$("$CLI" shell-env --config "$LONG_VALUE_CONFIG" -- prog --path "$long_value")"
if [ "$separated" != "$inline" ]; then
  printf 'Inline and separated forms disagree:\nInline:    %s\nSeparated: %s\n' "$inline" "$separated" >&2
  exit 1
fi

# [env] files: several .env files, read in order, later ones winning.
FILES_DIR="$ROOT_DIR/tests/dotenv-files"
files_output="$(cd "$FILES_DIR" && "$CLI" shell-env --config .cli-flags.toml -- prog)"
case "$files_output" in
  *"export F2E_FILES_PORT='3000'"*) ;;
  *) printf 'env.files did not read the first file:\n%s\n' "$files_output" >&2; exit 1 ;;
esac
case "$files_output" in
  *"export F2E_FILES_HOST='override'"*) ;;
  *) printf 'env.files: the later file should win:\n%s\n' "$files_output" >&2; exit 1 ;;
esac

# A path that escapes the working directory is an audit error, not a silent
# fallback to ./.env -- the contract is that only the cwd is read.
UNSAFE_DIR="$(mktemp -d)"
printf '[env]\nfiles = ["../.env"]\n\n[flags.a]\nenv = "F2E_UNSAFE_A"\naliases = ["a"]\ntype = "string"\n' \
  > "$UNSAFE_DIR/.cli-flags.toml"
set +e
unsafe_report="$("$CLI" audit "$UNSAFE_DIR/.cli-flags.toml")"
unsafe_status=$?
set -e
rm -rf "$UNSAFE_DIR"
if [ "$unsafe_status" -eq 0 ]; then
  printf 'env.files with a ".." segment should fail the audit:\n%s\n' "$unsafe_report" >&2
  exit 1
fi
case "$unsafe_report" in
  *"env.files must be a list of paths inside the working directory"*) ;;
  *) printf 'unexpected env.files audit message:\n%s\n' "$unsafe_report" >&2; exit 1 ;;
esac

# doctor: malformed lines are errors, ambiguous ones are warnings, and a key
# listed in [env] ignore is neither.
DOCTOR_DIR="$ROOT_DIR/tests/doctor-findings"
set +e
doctor_report="$(cd "$DOCTOR_DIR" && "$CLI" doctor .cli-flags.toml)"
doctor_status=$?
set -e
if [ "$doctor_status" -eq 0 ]; then
  printf 'doctor should exit non-zero on malformed .env lines:\n%s\n' "$doctor_report" >&2
  exit 1
fi
for expected in \
  'has an unterminated quote' \
  'no \"=\"' \
  'is not a valid environment variable name' \
  'was already assigned at line 2' \
  'F2E_DOCTOR_UNDECLARED is not declared'; do
  case "$doctor_report" in
    *"$expected"*) ;;
    *) printf 'doctor did not report %s:\n%s\n' "$expected" "$doctor_report" >&2; exit 1 ;;
  esac
done
# An [env] ignore entry is deliberately not reported as undeclared.
case "$doctor_report" in
  *"F2E_DOCTOR_IGNORED is not declared"*)
    printf 'doctor reported an env.ignore key as undeclared:\n%s\n' "$doctor_report" >&2
    exit 1 ;;
  *) ;;
esac
# Values never appear in the report: a .env holds secrets.
case "$doctor_report" in
  *second*|*nope*)
    printf 'doctor echoed a .env value:\n%s\n' "$doctor_report" >&2
    exit 1 ;;
  *) ;;
esac

# requires_tty: a flag that needs a terminal is refused without one.
#
# The failure being prevented is a CLI that waits forever on input nobody can
# give -- in CI, in cron, or on the far side of a pipe. The suite itself runs
# without a terminal, so the "no tty" cases need no setup; the "has tty" cases
# use the F2E_FORCE_* overrides rather than allocating a pty, which keeps the
# check identical on every platform.
TTY_CONFIG="$ROOT_DIR/tests/requires-tty/.cli-flags.toml"

tty_run() {
  "$CLI" shell-env --config "$TTY_CONFIG" -- prog "$@" || [ "$?" -eq 2 ]
}

# Refused: every spelling of setting it, including inside a short bundle.
for spelling in "--interactive" "-i" "-qi"; do
  refused="$(tty_run $spelling)"
  case "$refused" in
    *"flags.interactive requires an interactive terminal"*) ;;
    *) printf 'requires_tty did not refuse %s without a terminal:\n%s\n' \
         "$spelling" "$refused" >&2; exit 1 ;;
  esac
  case "$refused" in
    *"F2E_TTY_INTERACTIVE"*)
      printf 'a refused requires_tty flag must not be exported (%s):\n%s\n' \
        "$spelling" "$refused" >&2; exit 1 ;;
    *) ;;
  esac
done

# The separated form goes through a different code path than the bare one.
separated="$(tty_run --interactive true)"
case "$separated" in
  *"requires an interactive terminal"*) ;;
  *) printf 'requires_tty missed the separated form:\n%s\n' "$separated" >&2; exit 1 ;;
esac

# Turning it OFF must stay legal without a terminal: --no-interactive is
# exactly how a caller says "do not prompt".
negated="$(tty_run --no-interactive)"
case "$negated" in
  *"export F2E_TTY_INTERACTIVE='false'"*) ;;
  *) printf '--no-interactive should be allowed without a terminal:\n%s\n' "$negated" >&2; exit 1 ;;
esac

# A flag without requires_tty is untouched.
unrelated="$(tty_run --quiet)"
case "$unrelated" in
  *"export F2E_TTY_QUIET='true'"*) ;;
  *) printf 'requires_tty leaked onto an unrelated flag:\n%s\n' "$unrelated" >&2; exit 1 ;;
esac

# Allowed once stdin and stderr are terminals outside CI.
allowed="$(F2E_FORCE_STDIN_TTY=1 F2E_FORCE_STDERR_TTY=1 F2E_FORCE_CI=0 TERM=xterm tty_run --interactive)"
case "$allowed" in
  *"export F2E_TTY_INTERACTIVE='true'"*) ;;
  *) printf 'requires_tty refused an interactive terminal:\n%s\n' "$allowed" >&2; exit 1 ;;
esac

# CI and TERM=dumb defeat a real terminal: nobody is there to answer.
for hostile in "F2E_FORCE_CI=1" "TERM=dumb"; do
  blocked="$(env F2E_FORCE_STDIN_TTY=1 F2E_FORCE_STDERR_TTY=1 $hostile \
    "$CLI" shell-env --config "$TTY_CONFIG" -- prog --interactive)" || [ "$?" -eq 2 ]
  case "$blocked" in
    *"requires an interactive terminal"*) ;;
    *) printf '%s should defeat a terminal for requires_tty:\n%s\n' "$hostile" "$blocked" >&2; exit 1 ;;
  esac
done

# requires_tty = "stdout" asks about stdout specifically, not about prompting.
progress_blocked="$(F2E_FORCE_STDIN_TTY=1 F2E_FORCE_STDERR_TTY=1 tty_run --progress)"
case "$progress_blocked" in
  *"flags.progress requires a terminal on stdout"*) ;;
  *) printf 'requires_tty = stdout should check stdout:\n%s\n' "$progress_blocked" >&2; exit 1 ;;
esac
progress_allowed="$(F2E_FORCE_STDOUT_TTY=1 tty_run --progress)"
case "$progress_allowed" in
  *"export F2E_TTY_PROGRESS='true'"*) ;;
  *) printf 'requires_tty = stdout refused a stdout terminal:\n%s\n' "$progress_allowed" >&2; exit 1 ;;
esac

# A misspelled requires_tty must fail the audit rather than quietly meaning
# "no requirement" -- that would be a terminal check that silently is not one.
TTY_BAD_DIR="$(mktemp -d)"
printf '[flags.x]\nenv = "F2E_TTY_X"\naliases = ["x"]\ntype = "bool"\nrequires_tty = "sometimes"\n' \
  > "$TTY_BAD_DIR/.cli-flags.toml"
set +e
tty_bad="$("$CLI" audit "$TTY_BAD_DIR/.cli-flags.toml")"
tty_bad_status=$?
set -e
rm -rf "$TTY_BAD_DIR"
if [ "$tty_bad_status" -eq 0 ]; then
  printf 'an invalid requires_tty should fail the audit:\n%s\n' "$tty_bad" >&2
  exit 1
fi
case "$tty_bad" in
  *"requires_tty must be true, false, prompt, stdin, stdout, or stderr"*) ;;
  *) printf 'unexpected requires_tty audit message:\n%s\n' "$tty_bad" >&2; exit 1 ;;
esac

# parser.c detects terminals on its own because it must stay compilable as a
# single translation unit. terminal_context.c has its own detection. They have
# to agree, so assert it under the same forcing rather than trusting them to.
context_prompt="$(F2E_FORCE_STDIN_TTY=1 F2E_FORCE_STDERR_TTY=1 F2E_FORCE_CI=0 TERM=xterm \
  "$CLI" context 2>/dev/null || true)"
if [ -n "$context_prompt" ]; then
  case "$context_prompt" in
    *'"canPrompt": true'*|*'"canPrompt":true'*) ;;
    *)
      printf 'terminal context and parser disagree about canPrompt:\n%s\n' "$context_prompt" >&2
      exit 1 ;;
  esac
fi

# The forcing variables above are how the checks stay deterministic on every
# platform, but they are only worth trusting if they match a real terminal.
# When script(1) is available, run the two decisive cases through an actual pty
# and require the same answers. Skipped rather than failed where the flavour of
# script(1) differs, since this is corroboration, not the primary coverage.
# Probes by round-tripping a marker rather than by checking an exit status:
# whether script(1) can allocate a pty here depends on what stdin is, and the
# thing we need to know is "can I run a command under a pty and read what it
# printed", which is exactly what this asks.
f2e_pty_flavour=""
if script -q /dev/null printf f2e-pty-probe 2>/dev/null | grep -q f2e-pty-probe; then
  f2e_pty_flavour="bsd"          # macOS/BSD takes the command directly
elif script -q -c "printf f2e-pty-probe" /dev/null 2>/dev/null | grep -q f2e-pty-probe; then
  f2e_pty_flavour="util-linux"   # util-linux needs -c
fi

f2e_pty_run() {
  case "$f2e_pty_flavour" in
    bsd)        script -q /dev/null "$@" 2>/dev/null | tr -d '\r' ;;
    util-linux) script -q -c "$*" /dev/null 2>/dev/null | tr -d '\r' ;;
    *)          return 1 ;;
  esac
}

if pty_accepted="$(f2e_pty_run env -u COLUMNS -u CI -u GITHUB_ACTIONS TERM=xterm \
     "$CLI" shell-env --config "$TTY_CONFIG" -- prog --interactive)"; then
  case "$pty_accepted" in
    *"F2E_TTY_INTERACTIVE='true'"*) ;;
    *) printf 'a real terminal should allow --interactive:\n%s\n' "$pty_accepted" >&2; exit 1 ;;
  esac

  # CI must defeat a real terminal, not just a forced one.
  pty_ci="$(f2e_pty_run env -u COLUMNS TERM=xterm CI=1 \
    "$CLI" shell-env --config "$TTY_CONFIG" -- prog --interactive)"
  case "$pty_ci" in
    *"requires an interactive terminal"*) ;;
    *) printf 'CI should defeat a real terminal:\n%s\n' "$pty_ci" >&2; exit 1 ;;
  esac
  printf 'requires_tty: verified against a real pty\n'
else
  printf 'requires_tty: no usable script(1); pty corroboration skipped\n'
fi

# Help width is deterministic without a terminal: the table must not depend on
# the size of whatever terminal happened to launch the build.
piped_help="$(env -u COLUMNS "$CLI" --help | head -1)"
piped_width=${#piped_help}
if [ "$piped_width" -ne 80 ]; then
  printf 'piped --help should be 80 columns, got %s\n' "$piped_width" >&2
  exit 1
fi
# COLUMNS is the explicit override and still wins when piped.
wide_help="$(COLUMNS=140 "$CLI" --help | head -1)"
if [ "${#wide_help}" -ne 140 ]; then
  printf 'COLUMNS=140 should widen piped --help, got %s\n' "${#wide_help}" >&2
  exit 1
fi

# The shared short-bundle contract: one declarative case list that both this
# suite and the language clients assert against, so a binding cannot be green
# without having actually parsed a bundle. See
# scripts/verify-bundle-contract.py for why it exists.
if command -v python3 >/dev/null 2>&1; then
  python3 "$ROOT_DIR/scripts/verify-bundle-contract.py" --cli "$CLI" || exit 1
else
  printf 'bundle contract: no python3; skipped\n'
fi

printf 'flags2env tests passed\n'
