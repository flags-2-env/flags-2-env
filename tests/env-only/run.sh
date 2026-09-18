#!/usr/bin/env sh
set -eu
CLI="$1"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CFG="$DIR/.cli-flags.toml"

# Secret-bearing env-only keys remain first-class runtime inputs.
out="$(cd "$DIR" && DATABASE_URL='postgres://runtime-only' "$CLI" shell-env -- app)"
printf '%s\n' "$out" | grep -F "export DATABASE_URL='postgres://runtime-only'" >/dev/null
out="$(cd "$DIR" && NATS_URL='nats://runtime-only' "$CLI" shell-env -- app worker)"
printf '%s\n' "$out" | grep -F "export NATS_URL='nats://runtime-only'" >/dev/null

# argv=false does not remove the flag from typed/default/env resolution.
out="$(cd "$DIR" && "$CLI" shell-env -- app)"
printf '%s\n' "$out" | grep -F "export WORKER_CONCURRENCY='2'" >/dev/null
out="$(cd "$DIR" && WORKER_CONCURRENCY=7 "$CLI" shell-env -- app)"
printf '%s\n' "$out" | grep -F "export WORKER_CONCURRENCY='7'" >/dev/null

generated="$("$CLI" generate typescript "$CFG" --name EnvOnlyConfig)"
printf '%s\n' "$generated" | grep -F 'export interface EnvOnlyConfig' >/dev/null
printf '%s\n' "$generated" | grep -F 'WORKER_CONCURRENCY: number;' >/dev/null
printf '%s\n' "$generated" | grep -F 'DATABASE_URL?: string;' >/dev/null
printf '%s\n' "$generated" | grep -F 'NATS_URL?: string;' >/dev/null

# Env-only declarations never acquire a CLI presentation surface.
help="$(cd "$DIR" && "$CLI" app --help)"
! printf '%s\n' "$help" | grep -E 'database-url|DATABASE_URL|worker-concurrency|WORKER_CONCURRENCY' >/dev/null
worker_help="$(cd "$DIR" && "$CLI" app worker --help)"
! printf '%s\n' "$worker_help" | grep -E 'nats-url|NATS_URL|database-url|DATABASE_URL|worker-concurrency|WORKER_CONCURRENCY' >/dev/null
completion="$("$CLI" completion bash app "$CFG")"
! printf '%s\n' "$completion" | grep -E 'database-url|DATABASE_URL|worker-concurrency|WORKER_CONCURRENCY|nats-url|NATS_URL' >/dev/null

# allow_unknown=true must not suppress a declared env-only argv violation, and
# the diagnostic must never reflect the supplied value.
out="$(cd "$DIR" && "$CLI" app --database-url=supersecret)"
printf '%s\n' "$out" | grep -F 'env-only (argv = false)' >/dev/null
! printf '%s\n' "$out" | grep -F 'supersecret' >/dev/null
out="$(cd "$DIR" && "$CLI" app --worker-concurrency=9)"
printf '%s\n' "$out" | grep -F 'env-only (argv = false)' >/dev/null
! printf '%s\n' "$out" | grep -F '9' >/dev/null
out="$(cd "$DIR" && "$CLI" app worker --nats-url=nats-secret)"
printf '%s\n' "$out" | grep -F 'env-only (argv = false)' >/dev/null
! printf '%s\n' "$out" | grep -F 'nats-secret' >/dev/null

# Contradictory argv-only metadata is a configuration error.
for bad in invalid-alias.toml invalid-short.toml invalid-bool-alias.toml invalid-tty.toml invalid-argv.toml; do
  if "$CLI" audit "$DIR/$bad" >"$DIR/$bad.out" 2>&1; then
    echo "expected audit failure for $bad" >&2
    exit 1
  fi
done
grep -F 'argv = false cannot declare aliases' "$DIR/invalid-alias.toml.out" >/dev/null
grep -F 'argv = false cannot declare short' "$DIR/invalid-short.toml.out" >/dev/null
grep -F 'argv = false cannot declare boolean value aliases' "$DIR/invalid-bool-alias.toml.out" >/dev/null
grep -F 'argv = false cannot require a tty' "$DIR/invalid-tty.toml.out" >/dev/null
grep -F 'argv must be true or false' "$DIR/invalid-argv.toml.out" >/dev/null
rm -f "$DIR"/*.out

echo 'env-only argv=false tests passed'
