#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: publish-zed-compatibility.sh [--dry-run | --release]

Publishes the temporary flags-2-env/flags-2-env compatibility coordinate from
the same tagged commit as the canonical flags-2-env/flags-2-env package.
Defaults to --dry-run. Set ZED_BIN to select the reviewed zed executable.
EOF
}

mode=dry-run
case "${1:-}" in
  "" | --dry-run) ;;
  --release) mode=release ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
if (($# > 1)); then
  usage >&2
  exit 2
fi

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
zed_bin="${ZED_BIN:-zed}"
support_end=2026-08-19
policy_date="$(date -u +%F)"

if [[ "$policy_date" > "$support_end" ]]; then
  printf 'compatibility publication ended on %s (today is %s)\n' \
    "$support_end" "$policy_date" >&2
  exit 1
fi
if ! command -v "$zed_bin" >/dev/null 2>&1 && [[ ! -x "$zed_bin" ]]; then
  printf 'zed executable not found: %s\n' "$zed_bin" >&2
  exit 1
fi
if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  printf 'source checkout must be clean before compatibility publication\n' >&2
  exit 1
fi

read_manifest_field() {
  local field="$1"
  awk -F ' *= *' -v field="$field" '
    /^\[package\]$/ { in_package = 1; next }
    /^\[/ { in_package = 0 }
    in_package && $1 == field {
      value = $2
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$repo_root/.zpkg.toml"
}

canonical_org="$(read_manifest_field org)"
package_name="$(read_manifest_field name)"
package_version="$(read_manifest_field version)"
if [[ "$canonical_org/$package_name@$package_version" != \
  "flags-2-env/flags-2-env@0.3.0" ]]; then
  printf 'unexpected canonical package identity: %s/%s@%s\n' \
    "$canonical_org" "$package_name" "$package_version" >&2
  exit 1
fi

commit="$(git -C "$repo_root" rev-parse HEAD)"
tag="v$package_version"
tag_commit="$(git -C "$repo_root" rev-parse -q --verify "refs/tags/$tag^{commit}" || true)"
if [[ "$tag_commit" != "$commit" ]]; then
  printf 'required tag %s must resolve to HEAD %s before publication\n' \
    "$tag" "$commit" >&2
  exit 1
fi

stage_parent="$(mktemp -d "${TMPDIR:-/tmp}/flags2env-zed-compat.XXXXXX")"
stage="$stage_parent/source"
cleanup() {
  case "$stage_parent" in
    "${TMPDIR:-/tmp}/flags2env-zed-compat."*) rm -rf -- "$stage_parent" ;;
    *) printf 'refusing to remove unexpected temporary path: %s\n' "$stage_parent" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

git clone --no-hardlinks --quiet "$repo_root" "$stage"
git -C "$stage" switch --detach --quiet "$commit"
perl -pi -e 's/^org = "flags-2-env"$/org = "oresoftware"/' "$stage/.zpkg.toml"

changed="$(git -C "$stage" diff --name-only)"
if [[ "$changed" != ".zpkg.toml" ]]; then
  printf 'compatibility staging changed unexpected paths: %s\n' "$changed" >&2
  exit 1
fi
if [[ "$(git -C "$stage" diff --numstat -- .zpkg.toml)" != $'1\t1\t.zpkg.toml' ]]; then
  printf 'compatibility manifest overlay must change exactly one line\n' >&2
  exit 1
fi
if ! grep -Fxq 'org = "oresoftware"' "$stage/.zpkg.toml"; then
  printf 'compatibility manifest did not acquire the legacy package org\n' >&2
  exit 1
fi

publish_args=(publish --allow-dirty)
if [[ "$mode" == dry-run ]]; then
  publish_args+=(--dry-run)
fi
printf 'publishing flags-2-env/flags-2-env@%s from source commit %s (%s)\n' \
  "$package_version" "$commit" "$mode"
(cd "$stage" && "$zed_bin" "${publish_args[@]}")
