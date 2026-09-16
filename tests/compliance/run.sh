#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CHECKER="$ROOT_DIR/scripts/verify-consumer-compliance.py"
PARSER_REF="377bff1a4e7424eb98377997a232ddc0fc700f59"
LEGACY_UPSTREAM="https://github.com/"'ORESoftware'"/flags-2-env.git"
TMP_DIR="${TMPDIR:-/tmp}/flags2env-compliance-$$"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p \
  "$TMP_DIR/good" \
  "$TMP_DIR/bad-secret" \
  "$TMP_DIR/bad-unknown" \
  "$TMP_DIR/bad-pin" \
  "$TMP_DIR/bad-cwd" \
  "$TMP_DIR/legacy-good" \
  "$TMP_DIR/legacy-expired"

write_rust_files() {
  local dir="$1"
  local rev="$2"
  local extra="$3"
  local upstream="${4:-https://github.com/flags-2-env/flags-2-env.git}"
  cat >"$dir/Cargo.toml" <<EOF
[package]
name = "consumer"
version = "0.1.0"
edition = "2024"

[dependencies]
flags2env = { git = "$upstream", rev = "$rev"$extra }
EOF
  cat >"$dir/Cargo.lock" <<EOF
version = 4

[[package]]
name = "flags2env"
version = "0.1.0"
source = "git+$upstream?rev=$rev#$rev"
EOF
}

cat >"$TMP_DIR/good/.cli-flags.toml" <<'EOF'
[parse]
allow_unknown = false

[env]
ignore = ["DATABASE_URL", "OTEL_EXPORTER_OTLP_HEADERS"]

[flags.port]
env = "PORT"
type = "integer"
default = 8080

[flags.log-filter]
env = "RUST_LOG"
type = "string"
default = "info"
EOF
write_rust_files "$TMP_DIR/good" "$PARSER_REF" ""
python3 "$CHECKER" \
  --root "$TMP_DIR/good" \
  --contract .cli-flags.toml \
  --parser-ref "$PARSER_REF" \
  --kind server \
  --rust-manifest Cargo.toml

cp -R "$TMP_DIR/good/." "$TMP_DIR/legacy-good/"
write_rust_files \
  "$TMP_DIR/legacy-good" \
  "$PARSER_REF" \
  "" \
  "$LEGACY_UPSTREAM"
python3 "$CHECKER" \
  --root "$TMP_DIR/legacy-good" \
  --contract .cli-flags.toml \
  --parser-ref "$PARSER_REF" \
  --kind server \
  --rust-manifest Cargo.toml \
  --policy-date 2026-08-19

cp -R "$TMP_DIR/legacy-good/." "$TMP_DIR/legacy-expired/"
if python3 "$CHECKER" \
  --root "$TMP_DIR/legacy-expired" \
  --contract .cli-flags.toml \
  --parser-ref "$PARSER_REF" \
  --kind server \
  --rust-manifest Cargo.toml \
  --policy-date 2026-08-20; then
  echo "compatibility source should expire after 2026-08-19" >&2
  exit 1
fi

cp -R "$TMP_DIR/good/." "$TMP_DIR/bad-secret/"
cat >>"$TMP_DIR/bad-secret/.cli-flags.toml" <<'EOF'

[flags.database]
env = "DATABASE_URL"
type = "string"
EOF
if python3 "$CHECKER" --root "$TMP_DIR/bad-secret" --parser-ref "$PARSER_REF" --kind server --rust-manifest Cargo.toml; then
  echo "secret-bearing flag should fail compliance" >&2
  exit 1
fi

cp -R "$TMP_DIR/good/." "$TMP_DIR/bad-unknown/"
python3 - "$TMP_DIR/bad-unknown/.cli-flags.toml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace("allow_unknown = false", "allow_unknown = true"))
PY
if python3 "$CHECKER" --root "$TMP_DIR/bad-unknown" --parser-ref "$PARSER_REF" --kind cli --rust-manifest Cargo.toml; then
  echo "allow_unknown=true should fail compliance" >&2
  exit 1
fi

cp -R "$TMP_DIR/good/." "$TMP_DIR/bad-pin/"
write_rust_files "$TMP_DIR/bad-pin" "1111111111111111111111111111111111111111" ", branch = \"main\""
if python3 "$CHECKER" --root "$TMP_DIR/bad-pin" --parser-ref "$PARSER_REF" --kind worker --rust-manifest Cargo.toml; then
  echo "mutable or mismatched dependency pin should fail compliance" >&2
  exit 1
fi

cp -R "$TMP_DIR/good/." "$TMP_DIR/bad-cwd/"
mkdir -p "$TMP_DIR/bad-cwd/src"
cat >"$TMP_DIR/bad-cwd/src/flags.rs" <<'EOF'
use std::path::PathBuf;

fn resolve_contract() -> PathBuf {
    std::env::current_dir()
        .expect("current working directory")
        .join(".cli-flags.toml")
}
EOF
if python3 "$CHECKER" --root "$TMP_DIR/bad-cwd" --parser-ref "$PARSER_REF" --kind server --rust-manifest Cargo.toml; then
  echo "long-running consumer should not trust an ambient CWD contract" >&2
  exit 1
fi
python3 "$CHECKER" \
  --root "$TMP_DIR/bad-cwd" \
  --parser-ref "$PARSER_REF" \
  --kind cli \
  --rust-manifest Cargo.toml

if python3 "$CHECKER" --root "$TMP_DIR/good" --parser-ref main --kind server --rust-manifest Cargo.toml; then
  echo "non-immutable parser_ref should fail compliance" >&2
  exit 1
fi

echo "consumer compliance tests passed"
